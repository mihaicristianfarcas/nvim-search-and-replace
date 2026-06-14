-- Replace module - handles file replacements with undo/redo support
-- Uses exact match information from ripgrep JSON output for precise replacements
local M = {}

-- Undo/redo history (only changed lines, not full files)
local history = {}
local redo_stack = {}

-- History persistence configuration
local HISTORY_FILE = vim.fn.stdpath("cache") .. "/nvim-search-and-replace-history.json"
local MAX_HISTORY_ENTRIES = 50 -- Limit persisted history to prevent large files

-- Keeps only the most recent MAX_HISTORY_ENTRIES entries of a stack.
local function tail(stack)
	local out = {}
	local start_idx = math.max(1, #stack - MAX_HISTORY_ENTRIES + 1)
	for i = start_idx, #stack do
		out[#out + 1] = stack[i]
	end
	return out
end

-- Saves history to disk for cross-session persistence
local function save_history()
	-- Bound both stacks so the persisted file can't grow without limit
	local ok, encoded = pcall(vim.json.encode, { history = tail(history), redo_stack = tail(redo_stack) })
	if ok then
		local file = io.open(HISTORY_FILE, "w")
		if file then
			file:write(encoded)
			file:close()
		end
	end
end

-- Loads history from disk on module load
local function load_history()
	local file = io.open(HISTORY_FILE, "r")
	if not file then
		return
	end

	local content = file:read("*a")
	file:close()

	if not content or content == "" then
		return
	end

	local ok, data = pcall(vim.json.decode, content)
	if ok and data then
		history = data.history or {}
		redo_stack = data.redo_stack or {}
	end
end

-- Load history on module initialization
load_history()

-- Sorts entries by file, then line (descending), then column (descending)
-- This allows processing from bottom to top, avoiding line number shifts during replacement
local function sort_descending(entries)
	-- Pre-compute sort keys to avoid repeated string comparisons
	for i = 1, #entries do
		local e = entries[i]
		e._sort_key = string.format("%s:%09d:%09d", e.filename, 999999999 - (e.lnum or 0), 999999999 - (e.col or 0))
	end

	-- Simple string comparison is faster than multiple field checks
	table.sort(entries, function(a, b)
		return a._sort_key < b._sort_key
	end)

	-- Clean up temporary sort keys
	for i = 1, #entries do
		entries[i]._sort_key = nil
	end
end

-- Validates that entry has required fields
local function validate_entry(entry)
	return entry and entry.filename and entry.lnum and entry.col
end

-- Builds a matcher function for replacements
-- With ripgrep JSON output, we always have exact match info (match_text, match_len)
--
-- @param search: original search pattern (for error messages only)
-- @param match_text: exact string that was matched by ripgrep
-- @param match_len: length of the matched string
-- @return matcher table with match() function, or nil and error message
local function build_matcher(search, match_text, match_len)
	-- Use exact match info from ripgrep JSON output
	if match_text and match_len then
		return {
			mode = "exact",
			match = function(line, col)
				local start_idx = col
				local end_idx = col + match_len - 1
				local segment = string.sub(line, start_idx, end_idx)
				if segment == match_text then
					return start_idx, end_idx, segment
				end
				return nil, nil, segment
			end,
		}
	end

	-- Error case: missing match info
	return nil, "Missing match information from ripgrep JSON output"
end

-- Computes the new line after applying replacement using the provided matcher
-- @return new_line, start_idx, end_idx, error_message
local function compute_line_with_matcher(matcher, line, col, search, replace_text, match_text)
	local start_idx, end_idx, segment = matcher.match(line, col)
	if not start_idx then
		local expected = match_text or search
		local found = segment or "nothing"
		return nil, nil, segment, string.format("expected '%s' but found '%s'", expected, found)
	end

	local new_line = string.sub(line, 1, start_idx - 1) .. replace_text .. string.sub(line, end_idx + 1)
	return new_line, start_idx, end_idx, nil
end

-- Computes what a line would look like after replacement
-- Used by preview module to show before/after
-- @return new_line, start_idx, end_idx, error_message
function M.compute_line(line, col, search, replace_text, match_text, match_len)
	local matcher, err = build_matcher(search, match_text, match_len)
	if not matcher then
		return nil, nil, nil, err
	end
	return compute_line_with_matcher(matcher, line, col, search, replace_text, match_text)
end

-- Applies replacements to files based on search results
-- Processes files from bottom to top to avoid line number shifts
-- Stores only changed lines in history for efficient undo/redo
--
-- @param entries: array of search results with match_text and match_len
-- @param search: original search pattern (for error messages)
-- @param replace_text: text to replace matches with
-- @return summary table with: applied (count), files (array), skipped (array)
function M.apply(entries, search, replace_text)
	if not entries or #entries == 0 then
		vim.notify("No entries to replace.", vim.log.levels.WARN)
		return
	end

	if not search or search == "" then
		vim.notify("Search text is empty.", vim.log.levels.WARN)
		return
	end

	-- Group entries by file for efficient processing
	local per_file = {}
	for _, entry in ipairs(entries) do
		if validate_entry(entry) then
			local file_entries = per_file[entry.filename] or {}
			table.insert(file_entries, entry)
			per_file[entry.filename] = file_entries
		end
	end

	local summary = { applied = 0, files = {}, skipped = {} }
	local op_diffs = {} -- Differential storage: only changed lines, not full files

	-- Process files one at a time to avoid memory issues
	local files_to_process = {}
	for filename, _ in pairs(per_file) do
		table.insert(files_to_process, filename)
	end
	
	local files_processed = 0
	local total_files = #files_to_process
	
	-- Show progress for large operations
	local show_progress = total_files > 10
	
	for _, filename in ipairs(files_to_process) do
		local file_entries = per_file[filename]
		
		-- Sort bottom-to-top to avoid line number shifts during replacement
		sort_descending(file_entries)

		-- Use pcall to handle file read errors gracefully
		local ok, lines = pcall(vim.fn.readfile, filename)
		if not ok then
			table.insert(summary.skipped, filename .. ": failed to read file")
			goto continue
		end

		-- Track original lines for undo (only changed lines, not entire file)
		local original_lines = {}
		local file_applied = 0

		for _, entry in ipairs(file_entries) do
			local lnum = entry.lnum
			local col = entry.col
			local line = lines[lnum]

			if not line then
				table.insert(summary.skipped, string.format("%s:%d:%d missing line", filename, lnum, col))
			else
				-- Build matcher with exact match info from ripgrep JSON output
				local matcher, matcher_err = build_matcher(search, entry.match_text, entry.match_len)
				if not matcher then
					table.insert(
						summary.skipped,
						string.format("%s:%d:%d %s", filename, lnum, col, matcher_err or "matcher error")
					)
				else
					-- Attempt replacement with validation
					local new_line, _, _, err = compute_line_with_matcher(matcher, line, col, search, replace_text, entry.match_text)
					if new_line then
						-- Store original only once per line (handles multiple matches on same line)
						if not original_lines[lnum] then
							original_lines[lnum] = line
						end
						lines[lnum] = new_line
						file_applied = file_applied + 1
					else
						table.insert(
							summary.skipped,
							string.format("%s:%d:%d mismatch (%s)", filename, lnum, col, err or "no match")
						)
					end
				end
			end
		end

		-- Write changes if any replacements succeeded
		if file_applied > 0 then
			local ok_write, err = pcall(vim.fn.writefile, lines, filename)
			if ok_write then
				summary.applied = summary.applied + file_applied
				table.insert(summary.files, filename)
				-- Save diff for undo: keep both the original ("before") and the
				-- written ("after") text of each changed line. Storing "after"
				-- lets undo/redo verify the file hasn't drifted before touching it.
				local file_diff = {}
				for lnum, before in pairs(original_lines) do
					file_diff[lnum] = { before = before, after = lines[lnum] }
				end
				op_diffs[filename] = file_diff
			else
				table.insert(summary.skipped, string.format("%s: failed to write (%s)", filename, err))
			end
		end
		
		files_processed = files_processed + 1
		
		-- Yield to event loop periodically to keep UI responsive
		if files_processed % 5 == 0 then
			if show_progress then
				-- Use async notification to avoid blocking
				vim.schedule(function()
					vim.notify(
						string.format("Replacing: %d/%d files", files_processed, total_files),
						vim.log.levels.INFO
					)
				end)
			end
			-- Yield control briefly
			vim.cmd("redraw")
		end

		::continue::
	end

	if summary.applied > 0 then
		-- Add to history with differential storage (only changed lines)
		table.insert(history, { diffs = op_diffs, search = search, replace = replace_text, timestamp = os.time() })
		-- Clear redo stack when new operation is performed
		redo_stack = {}
		-- Persist history to disk
		save_history()
		-- Reload any open buffers that were modified to keep them in sync
		vim.schedule(function()
			vim.cmd("checktime")
		end)
	end

	return summary
end

-- Displays a notification summary of the replacement operation
function M.notify_summary(summary)
	if not summary then
		return
	end

	local message = string.format("Replaced %d occurrence(s) across %d file(s).", summary.applied, #summary.files)

	if summary.skipped and #summary.skipped > 0 then
		message = message .. "\n\nSkipped (text didn't match exactly at these locations):"
		for _, skip in ipairs(summary.skipped) do
			message = message .. "\n  • " .. skip
		end
	end

	vim.notify(message, vim.log.levels.INFO)
end

-- Resolves the (target, expected) text for one stored line diff.
-- direction "undo" restores `before` (expecting the line to currently hold `after`);
-- direction "redo" restores `after` (expecting the line to currently hold `before`).
-- Legacy diffs were plain "before" strings: those are restored without validation
-- (and only meaningfully support undo).
local function resolve_diff(diff, direction)
	if type(diff) == "table" then
		if direction == "undo" then
			return diff.before, diff.after
		end
		return diff.after, diff.before
	end
	-- Legacy format: bare "before" string, no recorded counterpart to validate against.
	return diff, nil
end

-- Applies an operation's stored line diffs in the given direction, validating
-- that each line still holds the expected text before overwriting it. Lines that
-- have drifted since the operation are skipped so we never clobber unrelated edits.
-- @return restored (file count), conflicts (array of "file:line"), failed (array)
local function restore_op(op, direction)
	local restored, conflicts, failed = 0, {}, {}

	for filename, line_diffs in pairs(op.diffs or {}) do
		local ok, lines = pcall(vim.fn.readfile, filename)
		if not ok then
			table.insert(failed, string.format("%s (cannot read)", filename))
		else
			local changed = false
			for lnum, diff in pairs(line_diffs) do
				local target, expected = resolve_diff(diff, direction)
				if target ~= nil then
					local current = lines[lnum]
					if current == target then
						-- Already in the desired state; nothing to do.
					elseif expected ~= nil and current ~= expected then
						-- File drifted since the operation was recorded; don't overwrite.
						table.insert(conflicts, string.format("%s:%d", filename, lnum))
					else
						lines[lnum] = target
						changed = true
					end
				end
			end

			if changed then
				local ok_write, err = pcall(vim.fn.writefile, lines, filename)
				if ok_write then
					restored = restored + 1
				else
					table.insert(failed, string.format("%s (%s)", filename, err))
				end
			end
		end
	end

	return restored, conflicts, failed
end

-- Builds and emits the notification for an undo/redo, then persists + reloads.
local function finish_restore(verb, restored, conflicts, failed, this_stack, other_label, other_count)
	save_history()

	-- Reload any open buffers that were modified to keep them in sync
	vim.schedule(function()
		vim.cmd("checktime")
	end)

	local msg = string.format("%s replace (%d file(s) restored).", verb, restored)
	if #this_stack > 0 then
		msg = msg .. string.format(" %d more %s available.", #this_stack, verb == "Undid" and "undo(s)" or "redo(s)")
	end
	if other_count > 0 then
		msg = msg .. string.format(" %d %s available.", other_count, other_label)
	end
	if #conflicts > 0 then
		msg = msg .. " Skipped (file changed since): " .. table.concat(conflicts, ", ")
	end
	if #failed > 0 then
		msg = msg .. " Failed: " .. table.concat(failed, "; ")
	end

	local level = (#failed > 0 or #conflicts > 0) and vim.log.levels.WARN or vim.log.levels.INFO
	vim.notify(msg, level)
end

-- Undoes the last replacement operation by restoring original lines from history.
-- The operation moves to the redo stack unchanged; its stored before/after pair
-- makes the reverse (redo) deterministic.
function M.undo_last()
	if #history == 0 then
		vim.notify("No replace operations to undo.", vim.log.levels.INFO)
		return
	end

	local op = table.remove(history)
	local restored, conflicts, failed = restore_op(op, "undo")
	table.insert(redo_stack, op)
	finish_restore("Undid", restored, conflicts, failed, history, "redo(s)", #redo_stack)
end

-- Redoes the last undone replacement operation.
-- Moves the operation from the redo stack back to history.
function M.redo_last()
	if #redo_stack == 0 then
		vim.notify("No replace operations to redo.", vim.log.levels.INFO)
		return
	end

	local op = table.remove(redo_stack)
	local restored, conflicts, failed = restore_op(op, "redo")
	table.insert(history, op)
	finish_restore("Redid", restored, conflicts, failed, redo_stack, "undo(s)", #history)
end

function M.get_history_count()
	return #history
end

function M.get_redo_count()
	return #redo_stack
end

return M
