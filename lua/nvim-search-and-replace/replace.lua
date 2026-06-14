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

-- Reads a file as raw bytes and splits it into logical lines, preserving each
-- line's exact terminator ("\n", "\r\n", or "" for a final line with no newline).
-- This lets us rewrite only the changed lines without altering a file's
-- line-ending style or its trailing-newline state.
-- @return lines (array), eols (array, parallel to lines) — or nil on read error
local function read_file(filename)
	local file = io.open(filename, "rb")
	if not file then
		return nil
	end
	local content = file:read("*a")
	file:close()
	content = content or ""

	local lines, eols = {}, {}
	local pos, len = 1, #content
	while pos <= len do
		local nl = content:find("\n", pos, true)
		if nl then
			local line = content:sub(pos, nl - 1)
			local eol = "\n"
			if line:sub(-1) == "\r" then
				line = line:sub(1, -2)
				eol = "\r\n"
			end
			lines[#lines + 1] = line
			eols[#eols + 1] = eol
			pos = nl + 1
		else
			-- Final chunk with no trailing newline
			lines[#lines + 1] = content:sub(pos)
			eols[#eols + 1] = ""
			pos = len + 1
		end
	end

	return lines, eols
end

-- Writes logical lines back as raw bytes, re-attaching each line's terminator.
-- @return ok (boolean), err (string|nil)
local function write_file(filename, lines, eols)
	local parts = {}
	for i = 1, #lines do
		parts[#parts + 1] = lines[i]
		parts[#parts + 1] = eols[i] or "\n"
	end

	local file, err = io.open(filename, "wb")
	if not file then
		return false, err or "cannot open for writing"
	end
	local ok, werr = file:write(table.concat(parts))
	file:close()
	if not ok then
		return false, werr or "write failed"
	end
	return true
end

-- Canonical absolute path with symlinks resolved, so a search-result path and an
-- open buffer's (possibly symlink-resolved) name can be compared reliably.
local function canonical(path)
	return vim.loop.fs_realpath(path) or vim.fn.fnamemodify(path, ":p")
end

-- True if the file is open in a loaded buffer with unsaved changes. Writing such
-- a file on disk would be silently overwritten the next time the buffer is saved
-- (and our checktime reload would clash), so callers skip these files instead.
local function has_unsaved_buffer(filename)
	local target = canonical(filename)
	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].modified then
			local name = vim.api.nvim_buf_get_name(b)
			if name ~= "" and canonical(name) == target then
				return true
			end
		end
	end
	return false
end

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

-- Computes a line-range edit for a single match against the current file lines.
-- Handles both single-line and multiline (newline-containing) matches uniformly.
-- The spanned region starts at the beginning of `lnum`, so `col` (1-indexed) is
-- also the match's byte offset within the region — which lets us validate the
-- exact matched bytes before changing anything.
-- @return edit { start = lnum, old = {orig lines}, new = {replacement lines} } or nil, err
local function compute_edit(lines, lnum, col, match_text, match_len, replace_text)
	if not match_text or not match_len then
		return nil, "missing match information"
	end

	-- How many extra lines the match spans (one per embedded newline)
	local _, num_nl = match_text:gsub("\n", "")
	local end_lnum = lnum + num_nl

	local old = {}
	for i = lnum, end_lnum do
		if not lines[i] then
			return nil, string.format("missing line %d", i)
		end
		old[#old + 1] = lines[i]
	end

	local region = table.concat(old, "\n")
	local segment = region:sub(col, col + match_len - 1)
	if segment ~= match_text then
		return nil, string.format("expected '%s' but found '%s'", match_text, segment)
	end

	-- Byte offset (1-indexed) just past the match on the last spanned line
	local end_col_last
	if num_nl == 0 then
		end_col_last = col + match_len - 1
	else
		end_col_last = #match_text:match("[^\n]*$") -- bytes after the final newline
	end

	local prefix = old[1]:sub(1, col - 1)
	local suffix = old[#old]:sub(end_col_last + 1)
	local new_content = prefix .. replace_text .. suffix

	-- The replacement itself may contain newlines, yielding multiple result lines
	local new = {}
	for s in (new_content .. "\n"):gmatch("(.-)\n") do
		new[#new + 1] = s
	end

	return { start = lnum, old = old, new = new }
end

-- Replaces lines[start .. start+old_count-1] with `new`, keeping the parallel
-- `eols` array in sync. Count-neutral edits mutate in place (cheap, and they
-- preserve each line's terminator exactly); count-changing edits rebuild the
-- arrays. New interior lines inherit the region's leading terminator and the
-- final new line inherits the region's trailing terminator (so a missing final
-- newline is preserved). Returns the (possibly new) lines, eols arrays.
local function splice(lines, eols, start, old_count, new)
	if #new == old_count then
		for i = 1, old_count do
			lines[start + i - 1] = new[i]
		end
		return lines, eols
	end

	local region_eol = eols[start] or "\n"
	local tail_eol = eols[start + old_count - 1] or "\n"
	local nl, ne = {}, {}
	for i = 1, start - 1 do
		nl[#nl + 1] = lines[i]
		ne[#ne + 1] = eols[i]
	end
	for i = 1, #new do
		nl[#nl + 1] = new[i]
		ne[#ne + 1] = (i < #new) and region_eol or tail_eol
	end
	for i = start + old_count, #lines do
		nl[#nl + 1] = lines[i]
		ne[#ne + 1] = eols[i]
	end
	return nl, ne
end

-- True if lines[start ..] matches every element of `arr`.
local function region_matches(lines, start, arr)
	for i = 1, #arr do
		if lines[start + i - 1] ~= arr[i] then
			return false
		end
	end
	return true
end

-- Computes the replacement lines for a match given the region of original lines
-- starting at the match's first line. Handles single- and multi-line matches.
-- Used by the preview to render a correct before/after. @return new_lines or nil
function M.compute_region(region_lines, col, replace_text, match_text, match_len)
	local edit = compute_edit(region_lines, 1, col, match_text, match_len, replace_text)
	return edit and edit.new or nil
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

	for _, filename in ipairs(files_to_process) do
		local file_entries = per_file[filename]

		-- Don't clobber a file the user is editing with unsaved changes
		if has_unsaved_buffer(filename) then
			table.insert(summary.skipped, filename .. ": buffer has unsaved changes (save or close it first)")
			goto continue
		end

		-- Sort bottom-to-top to avoid line number shifts during replacement
		sort_descending(file_entries)

		-- Read raw bytes, preserving line endings and trailing-newline state
		local lines, eols = read_file(filename)
		if not lines then
			table.insert(summary.skipped, filename .. ": failed to read file")
			goto continue
		end

		-- Edits recorded in apply order (entries are sorted bottom-to-top, so this
		-- is descending start line). Each edit captures the exact before/after
		-- line range, which lets undo/redo replay or reverse it safely even when
		-- a multiline replacement changes the file's line count.
		local edits = {}
		local file_applied = 0

		for _, entry in ipairs(file_entries) do
			local edit, err =
				compute_edit(lines, entry.lnum, entry.col, entry.match_text, entry.match_len, replace_text)
			if edit then
				lines, eols = splice(lines, eols, edit.start, #edit.old, edit.new)
				edits[#edits + 1] = edit
				file_applied = file_applied + 1
			else
				table.insert(
					summary.skipped,
					string.format("%s:%d:%d mismatch (%s)", filename, entry.lnum, entry.col, err or "no match")
				)
			end
		end

		-- Write changes if any replacements succeeded
		if file_applied > 0 then
			local ok_write, err = write_file(filename, lines, eols)
			if ok_write then
				summary.applied = summary.applied + file_applied
				table.insert(summary.files, filename)
				-- Store the ordered edits so undo/redo can validate and reverse them.
				op_diffs[filename] = { edits = edits }
			else
				table.insert(summary.skipped, string.format("%s: failed to write (%s)", filename, err))
			end
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

-- Normalizes a stored per-file diff into an ordered edits list (apply order:
-- descending start line). Handles the current { edits = {...} } format and two
-- legacy on-disk formats from earlier releases:
--   * { [lnum] = { before = , after = } }  -> single-line edit
--   * { [lnum] = "before_string" }          -> single-line, undo-only (no `after`)
local function normalize_edits(file_diff)
	if file_diff.edits then
		return file_diff.edits
	end

	local edits = {}
	for lnum, d in pairs(file_diff) do
		if type(d) == "table" then
			edits[#edits + 1] = { start = lnum, old = { d.before }, new = { d.after } }
		else
			edits[#edits + 1] = { start = lnum, old = { d } } -- no recorded `new`
		end
	end
	table.sort(edits, function(a, b)
		return a.start > b.start
	end)
	return edits
end

-- Applies an operation's stored edits in the given direction, validating that
-- each region still holds the expected text before changing it, so unrelated
-- edits since the operation are never clobbered.
--   * "redo" replays edits in apply order (old -> new)
--   * "undo" reverses them (new -> old)
-- A region that has drifted is reported as a conflict and skipped; if skipping it
-- would desync later line numbers (a multiline edit that changed the line count),
-- the whole file is aborted unwritten so it can't be corrupted.
-- @return restored (file count), conflicts (array of "file:line"), failed (array)
-- Restores one file's edits. Mutates the shared conflicts/failed arrays and
-- returns true if the file was written (counts toward "files restored").
local function restore_file(filename, file_diff, undo, conflicts, failed)
	if has_unsaved_buffer(filename) then
		table.insert(conflicts, filename .. " (unsaved buffer)")
		return false
	end

	local lines, eols = read_file(filename)
	if not lines then
		table.insert(failed, string.format("%s (cannot read)", filename))
		return false
	end

	local edits = normalize_edits(file_diff)

	-- redo follows apply (stored) order; undo reverses it
	local order = {}
	if undo then
		for i = #edits, 1, -1 do
			order[#order + 1] = edits[i]
		end
	else
		order = edits
	end

	local changed, aborted = false, false
	for _, edit in ipairs(order) do
		local target = undo and edit.old or edit.new
		local expected = undo and edit.new or edit.old
		if target == nil then
			-- Legacy entry with no counterpart for this direction; skip.
		elseif region_matches(lines, edit.start, target) then
			-- Already in the desired state; nothing to do.
		elseif expected == nil then
			-- Legacy single-line undo without an `after` to validate against.
			lines[edit.start] = target[1]
			changed = true
		elseif region_matches(lines, edit.start, expected) then
			lines, eols = splice(lines, eols, edit.start, #expected, target)
			changed = true
		else
			-- Region drifted since the operation was recorded.
			table.insert(conflicts, string.format("%s:%d", filename, edit.start))
			if #expected ~= #target then
				aborted = true
				break -- skipping a count-changing edit would desync the rest
			end
		end
	end

	if aborted or not changed then
		return false
	end

	local ok_write, err = write_file(filename, lines, eols)
	if not ok_write then
		table.insert(failed, string.format("%s (%s)", filename, err))
		return false
	end
	return true
end

local function restore_op(op, direction)
	local restored, conflicts, failed = 0, {}, {}
	local undo = direction == "undo"

	for filename, file_diff in pairs(op.diffs or {}) do
		if restore_file(filename, file_diff, undo, conflicts, failed) then
			restored = restored + 1
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
