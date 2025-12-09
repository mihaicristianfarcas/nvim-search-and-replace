-- Preview module - handles preview window updates with context and before/after comparison
-- Uses ripgrep JSON match information for precise highlighting in regex mode
-- Implements file caching and debouncing for smooth navigation
local M = {}

local replacer = require("nvim-search-and-replace.replace")
local uv = vim.loop

-- Simple LRU cache for file content (stores last 5 files)
local file_cache = {}
local cache_order = {}
local MAX_CACHE_SIZE = 5
local MAX_CONTEXT_LINES = 100  -- Maximum lines of context around match
local MAX_LINE_LENGTH = 500    -- Truncate very long lines

-- Single debounce timer - only one preview operation at a time
local preview_timer = nil
local pending_preview = nil

-- Reads specific line range from file with caching for performance
-- @return lines array, starting line number
local function read_lines_range(filename, start_line, end_line)
	-- Check cache first
	local cache_key = filename
	if file_cache[cache_key] then
		local cached_lines = {}
		local has_all = true
		for i = start_line, end_line do
			if file_cache[cache_key][i] then
				table.insert(cached_lines, file_cache[cache_key][i])
			else
				has_all = false
				break
			end
		end
		if has_all and #cached_lines > 0 then
			return cached_lines, start_line
		end
	end

	-- read from disk synchronously but with line limit
	local lines = {}
	local file = io.open(filename, "r")
	if not file then
		return nil, nil
	end

	local current = 0
	for line in file:lines() do
		current = current + 1
		if current >= start_line then
			-- truncate long lines
			if #line > MAX_LINE_LENGTH then
				line = line:sub(1, MAX_LINE_LENGTH) .. "... (truncated)"
			end
			table.insert(lines, line)
			if current >= end_line then
				break
			end
		end
	end
	file:close()

	-- update cache
	if not file_cache[cache_key] then
		file_cache[cache_key] = {}
		table.insert(cache_order, cache_key)

		-- maintain cache size
		if #cache_order > MAX_CACHE_SIZE then
			local old_key = table.remove(cache_order, 1)
			file_cache[old_key] = nil
		end
	end

	-- store in cache
	for i, line in ipairs(lines) do
		file_cache[cache_key][start_line + i - 1] = line
	end

	return lines, start_line
end

-- Performs the actual preview update synchronously
-- Shows before/after comparison with context lines
-- Highlights exact matches using ripgrep JSON match information
local function do_preview_update(preview_buf, result, search_text, replace_text, smart_case)
	if not vim.api.nvim_buf_is_valid(preview_buf) then
		return
	end

	if not result then
		vim.bo[preview_buf].modifiable = true
		vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, { "No selection" })
		vim.bo[preview_buf].modifiable = false
		return
	end

	smart_case = smart_case ~= false -- Default to true
	-- Determine if search should be case-insensitive
	local case_insensitive = smart_case and search_text == search_text:lower()

	-- get preview window
	local preview_win = nil
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_get_buf(win) == preview_buf then
			preview_win = win
			break
		end
	end

	local win_height = preview_win and vim.api.nvim_win_get_height(preview_win) or 40
	local context_lines = math.min(math.floor(win_height / 2), MAX_CONTEXT_LINES)

	local lnum = result.lnum
	local start_line = math.max(1, lnum - context_lines)
	local end_line = lnum + context_lines

	-- read file synchronously
	local file_lines, offset = read_lines_range(result.filename, start_line, end_line)
	if not file_lines then
		vim.bo[preview_buf].modifiable = true
		vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, { "Cannot read file" })
		vim.bo[preview_buf].modifiable = false
		return
	end

	end_line = math.min(offset + #file_lines - 1, lnum + context_lines)

	local preview_lines = {}
	local before_line_idx = nil
	local after_line_idx = nil
	local matched_line_idx = nil

	-- add filename header
	local cwd = vim.loop.cwd()
	local rel_path = result.filename
	if rel_path:sub(1, #cwd) == cwd then
		rel_path = rel_path:sub(#cwd + 2)
	end
	table.insert(preview_lines, "╔═══ " .. rel_path .. " ═══")
	table.insert(preview_lines, "")

	-- build preview content
	for i = start_line, end_line do
		local line_idx = i - offset + 1
		local line = file_lines[line_idx] or ""
		local prefix = string.format("%4d │", i)

		if i == lnum and replace_text ~= "" then
			local new_line =
				replacer.compute_line(line, result.col, search_text, replace_text, result.match_text, result.match_len)

			table.insert(preview_lines, "")
			table.insert(preview_lines, "      >>>>>>")
			before_line_idx = #preview_lines + 1
			matched_line_idx = before_line_idx
			table.insert(preview_lines, prefix .. " " .. line)
			table.insert(preview_lines, "      <<<<<<")
			after_line_idx = #preview_lines + 1
			table.insert(preview_lines, prefix .. " " .. (new_line or line))
			table.insert(preview_lines, "")
		else
			table.insert(preview_lines, prefix .. " " .. line)
			if i == lnum then
				matched_line_idx = #preview_lines
			end
		end
	end

	vim.bo[preview_buf].modifiable = true
	vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, preview_lines)

	-- set filetype for syntax highlighting
	local filetype = vim.filetype.match({ filename = result.filename })
	if filetype then
		vim.bo[preview_buf].filetype = filetype
	end

	vim.bo[preview_buf].modifiable = false

	-- apply highlights
	local ns = vim.api.nvim_create_namespace("nvim_search_and_replace_preview")
	vim.api.nvim_buf_clear_namespace(preview_buf, ns, 0, -1)
	vim.api.nvim_buf_add_highlight(preview_buf, ns, "Title", 0, 0, -1)

	for i, line in ipairs(preview_lines) do
		if line:match("^%s*%d+%s*│") then
			local num_end = line:find("│")
			if num_end then
				vim.api.nvim_buf_add_highlight(preview_buf, ns, "LineNr", i - 1, 0, num_end)
			end
		end
	end

	if before_line_idx then
		vim.api.nvim_buf_add_highlight(preview_buf, ns, "DiffDelete", before_line_idx - 1, 0, -1)
	end
	if after_line_idx then
		vim.api.nvim_buf_add_highlight(preview_buf, ns, "DiffAdd", after_line_idx - 1, 0, -1)
	end

	if search_text ~= "" then
		for i, line in ipairs(preview_lines) do
			local content_start = line:find("│")
			if content_start then
				local content_offset = content_start + 3
				local is_matched_line = (i == matched_line_idx)
				local content = line:sub(content_offset + 1)

				if result and result.match_text and result.match_len then
					-- Use exact match info from ripgrep JSON output
					-- Only highlight on the actual matched line
					if is_matched_line then
						local match_text = result.match_text
						-- Find the match in the content
						local match_start = content:find(match_text, 1, true)
						if match_start then
							local abs_start = content_offset + match_start
							
							vim.api.nvim_buf_add_highlight(
								preview_buf,
								ns,
								"IncSearch",
								i - 1,
								abs_start - 1,
								abs_start - 1 + result.match_len
							)
						end
					end
				elseif case_insensitive then
					-- Case-insensitive highlighting
					local search_lower = search_text:lower()
					local content_lower = content:lower()
					local pos = 1

					while true do
						local match_start, match_end = content_lower:find(search_lower, pos, true)
						if not match_start then
							break
						end

						local abs_start = content_offset + match_start
						local col_in_original = match_start
						local is_the_match = is_matched_line and (col_in_original == result.col)

						vim.api.nvim_buf_add_highlight(
							preview_buf,
							ns,
							is_the_match and "IncSearch" or "Search",
							i - 1,
							abs_start - 1,
							abs_start - 1 + (match_end - match_start + 1)
						)
						pos = match_end + 1
					end
				else
					-- Case-sensitive highlighting
					local search_start = 1

					while true do
						local match_start, match_end = content:find(search_text, search_start, true)
						if not match_start then
							break
						end

						local abs_start = content_offset + match_start
						local col_in_original = match_start
						local is_the_match = is_matched_line and (col_in_original == result.col)

						vim.api.nvim_buf_add_highlight(
							preview_buf,
							ns,
							is_the_match and "IncSearch" or "Search",
							i - 1,
							abs_start - 1,
							abs_start - 1 + #search_text
						)
						search_start = match_end + 1
					end
				end
			end
		end
	end

	-- center matched line
	if preview_win and matched_line_idx and vim.api.nvim_win_is_valid(preview_win) then
		pcall(vim.api.nvim_win_set_cursor, preview_win, { matched_line_idx, 0 })
		pcall(vim.api.nvim_win_call, preview_win, function()
			vim.cmd("normal! zz")
		end)
	end
end

-- Debounces by 50ms to smooth out UI updates when scrolling through results
function M.update(preview_buf, result, search_text, replace_text, smart_case)
	-- Cancel any pending preview
	if preview_timer then
		vim.fn.timer_stop(preview_timer)
		preview_timer = nil
	end

	smart_case = smart_case ~= false -- Default to true

	-- Store the pending preview params
	pending_preview = {
		buf = preview_buf,
		result = result,
		search = search_text,
		replace = replace_text,
		smart_case = smart_case,
	}

	-- debounce by 50ms to prevent glitching when navigating during active search
	preview_timer = vim.fn.timer_start(50, function()
		preview_timer = nil
		if pending_preview then
			local p = pending_preview
			pending_preview = nil

			-- run in vim.schedule to yield control
			vim.schedule(function()
				do_preview_update(p.buf, p.result, p.search, p.replace, p.smart_case)
			end)
		end
	end)
end

return M
