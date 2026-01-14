-- Replace module - handles file replacements with undo/redo support
-- Uses exact match information from ripgrep JSON output for precise replacements
local M = {}

-- Undo/redo history (only changed lines, not full files)
local history = {}
local redo_stack = {}

-- History persistence configuration
local HISTORY_FILE = vim.fn.stdpath("cache") .. "/nvim-search-and-replace-history.json"
local MAX_HISTORY_ENTRIES = 50 -- Limit persisted history to prevent large files

-- Saves history to disk for cross-session persistence
local function save_history()
	-- Only save a limited number of recent entries
	local to_save = {}
	local start_idx = math.max(1, #history - MAX_HISTORY_ENTRIES + 1)
	for i = start_idx, #history do
		to_save[#to_save + 1] = history[i]
	end

	local ok, encoded = pcall(vim.json.encode, { history = to_save, redo_stack = redo_stack })
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
				-- Save diff for undo (only changed lines, not entire file)
				op_diffs[filename] = original_lines
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

-- Undoes the last replacement operation by restoring original lines from history
function M.undo_last()
	if #history == 0 then
		vim.notify("No replace operations to undo.", vim.log.levels.INFO)
		return
	end

	local op = table.remove(history)
	if not op then
		vim.notify("No replace operations to undo.", vim.log.levels.INFO)
		return
	end

	-- Save current state for potential redo (only changed lines)
	local current_diffs = {}
	for filename, original_lines in pairs(op.diffs or {}) do
		local ok, lines = pcall(vim.fn.readfile, filename)
		if ok then
			-- Store only the lines that changed
			local current_changed = {}
			for lnum, _ in pairs(original_lines) do
				if lines[lnum] then
					current_changed[lnum] = lines[lnum]
				end
			end
			current_diffs[filename] = current_changed
		end
	end

	local restored, failed = 0, {}
	for filename, original_lines in pairs(op.diffs or {}) do
		local ok, lines = pcall(vim.fn.readfile, filename)
		if ok then
			-- Restore only the changed lines to their original values
			for lnum, original_line in pairs(original_lines) do
				lines[lnum] = original_line
			end
			local ok_write, err = pcall(vim.fn.writefile, lines, filename)
			if ok_write then
				restored = restored + 1
			else
				table.insert(failed, string.format("%s (%s)", filename, err))
			end
		else
			table.insert(failed, string.format("%s (cannot read)", filename))
		end
	end

	-- Add to redo stack with differential storage
	table.insert(redo_stack, {
		diffs = current_diffs,
		search = op.search,
		replace = op.replace,
		timestamp = op.timestamp,
	})

	-- Persist history to disk
	save_history()

	-- Reload any open buffers that were modified to keep them in sync
	vim.schedule(function()
		vim.cmd("checktime")
	end)

	local msg = string.format("Undid replace (%d file(s) restored).", restored)
	if #history > 0 then
		msg = msg .. string.format(" %d more undo(s) available.", #history)
	end
	if #redo_stack > 0 then
		msg = msg .. string.format(" %d redo(s) available.", #redo_stack)
	end
	if #failed > 0 then
		msg = msg .. " Failed: " .. table.concat(failed, "; ")
	end
	vim.notify(msg, #failed > 0 and vim.log.levels.WARN or vim.log.levels.INFO)
end

-- Redoes the last undone replacement operation
-- Moves operation from redo stack back to history
function M.redo_last()
	if #redo_stack == 0 then
		vim.notify("No replace operations to redo.", vim.log.levels.INFO)
		return
	end

	local op = table.remove(redo_stack)
	if not op then
		vim.notify("No replace operations to redo.", vim.log.levels.INFO)
		return
	end

	-- save current changed lines before restoring for undo
	local current_diffs = {}
	for filename, changed_lines in pairs(op.diffs or {}) do
		local ok, lines = pcall(vim.fn.readfile, filename)
		if ok then
			-- store only the lines that will be changed
			local current_changed = {}
			for lnum, _ in pairs(changed_lines) do
				if lines[lnum] then
					current_changed[lnum] = lines[lnum]
				end
			end
			current_diffs[filename] = current_changed
		end
	end

	local restored, failed = 0, {}
	for filename, changed_lines in pairs(op.diffs or {}) do
		local ok, lines = pcall(vim.fn.readfile, filename)
		if ok then
			-- restore only the changed lines
			for lnum, changed_line in pairs(changed_lines) do
				lines[lnum] = changed_line
			end
			local ok_write, err = pcall(vim.fn.writefile, lines, filename)
			if ok_write then
				restored = restored + 1
			else
				table.insert(failed, string.format("%s (%s)", filename, err))
			end
		else
			table.insert(failed, string.format("%s (cannot read)", filename))
		end
	end

	-- add back to history with differential storage
	table.insert(history, {
		diffs = current_diffs,
		search = op.search,
		replace = op.replace,
		timestamp = op.timestamp,
	})

	-- Persist history to disk
	save_history()

	-- Reload any open buffers that were modified to keep them in sync
	vim.schedule(function()
		vim.cmd("checktime")
	end)

	local msg = string.format("Redid replace (%d file(s) restored).", restored)
	if #redo_stack > 0 then
		msg = msg .. string.format(" %d more redo(s) available.", #redo_stack)
	end
	if #history > 0 then
		msg = msg .. string.format(" %d undo(s) available.", #history)
	end
	if #failed > 0 then
		msg = msg .. " Failed: " .. table.concat(failed, "; ")
	end
	vim.notify(msg, #failed > 0 and vim.log.levels.WARN or vim.log.levels.INFO)
end

function M.get_history_count()
	return #history
end

function M.get_redo_count()
	return #redo_stack
end

return M
