local M = {}

-- history stores differential undo information (only changed lines)
local history = {}
local redo_stack = {}

-- regex cache for performance (weak values allow gc when not in use)
local regex_cache = setmetatable({}, { __mode = "v" })

-- sorts entries by file, then line (descending), then column (descending)
-- this allows processing from bottom to top, avoiding line number shifts
local function sort_descending(entries)
	-- pre-compute sort keys to avoid repeated string comparisons
	for i = 1, #entries do
		local e = entries[i]
		e._sort_key = string.format("%s:%09d:%09d", e.filename, 999999999 - (e.lnum or 0), 999999999 - (e.col or 0))
	end

	-- simple string comparison is faster than multiple field checks
	table.sort(entries, function(a, b)
		return a._sort_key < b._sort_key
	end)

	-- clean up temporary sort keys
	for i = 1, #entries do
		entries[i]._sort_key = nil
	end
end

-- validates that entry has required fields
local function validate_entry(entry)
	return entry and entry.filename and entry.lnum and entry.col
end

-- builds a matcher function for either literal or regex search
local function build_matcher(search, opts)
	opts = opts or {}

	-- literal mode: exact string matching
	if opts.literal ~= false then
		return {
			mode = "literal",
			match = function(line, col)
				local start_idx = col
				local end_idx = col + #search - 1
				local segment = string.sub(line, start_idx, end_idx)
				if segment == search then
					return start_idx, end_idx, segment
				end
				return nil, nil, segment
			end,
		}
	end

	-- regex mode: check cache first to avoid recompiling
	local cache_key = search .. ":regex"
	local cached_matcher = regex_cache[cache_key]
	if cached_matcher then
		return cached_matcher
	end

	-- compile new regex pattern
	local ok, regex = pcall(vim.regex, search)
	if not ok or not regex then
		return nil, "Invalid regex: " .. tostring(search)
	end

	local matcher = {
		mode = "regex",
		match = function(line, col)
			-- extract substring starting at col for matching
			local sub = string.sub(line, col)
			local s, e = regex:match_str(sub)
			if not s or s ~= 0 then
				return nil, nil, nil
			end
			local start_idx = col
			local end_idx = col + e - 1
			local matched = string.sub(line, start_idx, end_idx)
			return start_idx, end_idx, matched
		end,
	}

	-- cache for future use
	regex_cache[cache_key] = matcher
	return matcher
end

local function compute_line_with_matcher(matcher, line, col, search, replace_text)
	local start_idx, end_idx, segment = matcher.match(line, col)
	if not start_idx then
		local expected = search
		local found = segment or "nothing"
		return nil, nil, segment, string.format("expected '%s' but found '%s'", expected, found)
	end

	local new_line = string.sub(line, 1, start_idx - 1) .. replace_text .. string.sub(line, end_idx + 1)
	return new_line, start_idx, end_idx, nil
end

function M.compute_line(line, col, search, replace_text, opts)
	local matcher, err = build_matcher(search, opts)
	if not matcher then
		return nil, nil, nil, err
	end
	return compute_line_with_matcher(matcher, line, col, search, replace_text)
end

function M.apply(entries, search, replace_text, opts)
	opts = opts or {}

	if not entries or #entries == 0 then
		vim.notify("No entries to replace.", vim.log.levels.WARN)
		return
	end

	if not search or search == "" then
		vim.notify("Search text is empty.", vim.log.levels.WARN)
		return
	end

	local matcher, matcher_err = build_matcher(search, opts)
	if not matcher then
		vim.notify(matcher_err or "Invalid search pattern.", vim.log.levels.WARN)
		return
	end

	-- group entries by file for efficient processing
	local per_file = {}
	for _, entry in ipairs(entries) do
		if validate_entry(entry) then
			local file_entries = per_file[entry.filename] or {}
			table.insert(file_entries, entry)
			per_file[entry.filename] = file_entries
		end
	end

	local summary = { applied = 0, files = {}, skipped = {} }
	local op_diffs = {} -- differential storage: only changed lines, not full files

	for filename, file_entries in pairs(per_file) do
		-- sort bottom-to-top to avoid line number shifts during replacement
		sort_descending(file_entries)

		local ok, lines = pcall(vim.fn.readfile, filename)
		if not ok then
			table.insert(summary.skipped, filename .. ": failed to read file")
			goto continue
		end

		-- track original lines for undo
		local original_lines = {}
		local file_applied = 0

		for _, entry in ipairs(file_entries) do
			local lnum = entry.lnum
			local col = entry.col
			local line = lines[lnum]

			if not line then
				table.insert(summary.skipped, string.format("%s:%d:%d missing line", filename, lnum, col))
			else
				-- attempt replacement with validation
				local new_line, _, _, err = compute_line_with_matcher(matcher, line, col, search, replace_text)
				if new_line then
					-- store original only once per line (first modification)
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

		-- write changes if any replacements succeeded
		if file_applied > 0 then
			local ok_write, err = pcall(vim.fn.writefile, lines, filename)
			if ok_write then
				summary.applied = summary.applied + file_applied
				table.insert(summary.files, filename)
				-- save diff for undo (only changed lines, not entire file)
				op_diffs[filename] = original_lines
			else
				table.insert(summary.skipped, string.format("%s: failed to write (%s)", filename, err))
			end
		end

		::continue::
	end

	if summary.applied > 0 then
		-- add to history with differential storage (only changed lines)
		table.insert(history, { diffs = op_diffs, search = search, replace = replace_text, timestamp = os.time() })
		-- clear redo stack when new operation is performed
		redo_stack = {}
	end

	return summary
end

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

-- undoes the last replacement operation
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

	-- save current state for potential redo
	local current_diffs = {}
	for filename, original_lines in pairs(op.diffs or {}) do
		local ok, lines = pcall(vim.fn.readfile, filename)
		if ok then
			-- store only the lines that changed
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
			-- restore only the changed lines
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

	-- add to redo stack with differential storage
	table.insert(redo_stack, {
		diffs = current_diffs,
		search = op.search,
		replace = op.replace,
		timestamp = op.timestamp,
	})

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
