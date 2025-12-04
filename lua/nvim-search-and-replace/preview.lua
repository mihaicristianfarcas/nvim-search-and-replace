-- Preview module - handles preview window updates
local M = {}

local replacer = require("nvim-search-and-replace.replace")

function M.update(preview_buf, result, search_text, replace_text, use_regex)
	if not preview_buf or not vim.api.nvim_buf_is_valid(preview_buf) then
		return
	end

	-- Make buffer modifiable temporarily
	vim.api.nvim_buf_set_option(preview_buf, "modifiable", true)

	if not result then
		vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, { "No selection" })
		vim.api.nvim_buf_set_option(preview_buf, "modifiable", false)
		return
	end

	local ok, file_lines = pcall(vim.fn.readfile, result.filename)
	if not ok then
		vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, { "Cannot read file" })
		vim.api.nvim_buf_set_option(preview_buf, "modifiable", false)
		return
	end

	-- Get preview window height to calculate centering
	local preview_win = nil
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_get_buf(win) == preview_buf then
			preview_win = win
			break
		end
	end

	local win_height = preview_win and vim.api.nvim_win_get_height(preview_win) or 40
	local context_lines = math.floor(win_height / 2)

	local lnum = result.lnum
	local context_before = context_lines
	local context_after = context_lines
	local start_line = math.max(1, lnum - context_before)
	local end_line = math.min(#file_lines, lnum + context_after)

	local preview_lines = {}
	local before_line_idx = nil
	local after_line_idx = nil
	local matched_line_idx = nil

	-- Add filename header
	local cwd = vim.loop.cwd()
	local rel_path = result.filename
	if rel_path:sub(1, #cwd) == cwd then
		rel_path = rel_path:sub(#cwd + 2)
	end
	table.insert(preview_lines, "╔═══ " .. rel_path .. " ═══")
	table.insert(preview_lines, "")

	-- Show context with before/after
	for i = start_line, end_line do
		local line = file_lines[i] or ""
		local prefix = string.format("%4d │", i)

		if i == lnum and replace_text ~= "" then
			-- Show the change
			local new_line =
				replacer.compute_line(line, result.col, search_text, replace_text, { literal = not use_regex })

			table.insert(preview_lines, "")
			table.insert(preview_lines, "      BEFORE:")
			before_line_idx = #preview_lines + 1
			matched_line_idx = before_line_idx -- Track the actual matched line
			table.insert(preview_lines, prefix .. " " .. line)
			table.insert(preview_lines, "      AFTER:")
			after_line_idx = #preview_lines + 1
			table.insert(preview_lines, prefix .. " " .. (new_line or line))
			table.insert(preview_lines, "")
		else
			table.insert(preview_lines, prefix .. " " .. line)
			-- Track matched line even when no replace text
			if i == lnum then
				matched_line_idx = #preview_lines
			end
		end
	end

	vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, preview_lines)

	-- Detect filetype and enable syntax highlighting
	local filetype = vim.filetype.match({ filename = result.filename })
	if filetype then
		vim.api.nvim_buf_set_option(preview_buf, "filetype", filetype)
	end

	-- Set back to non-modifiable
	vim.api.nvim_buf_set_option(preview_buf, "modifiable", false)

	-- Highlight the changed line
	local ns = vim.api.nvim_create_namespace("nvim_search_and_replace_preview")
	vim.api.nvim_buf_clear_namespace(preview_buf, ns, 0, -1)

	-- Highlight header
	vim.api.nvim_buf_add_highlight(preview_buf, ns, "Title", 0, 0, -1)

	-- Highlight line numbers for all lines
	for i, line in ipairs(preview_lines) do
		if line:match("^%s*%d+%s*│") then
			local num_end = line:find("│")
			if num_end then
				vim.api.nvim_buf_add_highlight(preview_buf, ns, "LineNr", i - 1, 0, num_end)
			end
		end
	end

	-- Highlight the actual BEFORE and AFTER content lines (not the labels)
	if before_line_idx then
		vim.api.nvim_buf_add_highlight(preview_buf, ns, "DiffDelete", before_line_idx - 1, 0, -1)
	end
	if after_line_idx then
		vim.api.nvim_buf_add_highlight(preview_buf, ns, "DiffAdd", after_line_idx - 1, 0, -1)
	end

	-- Highlight the search term in preview - distinctive highlight for the matched occurrence
	if search_text ~= "" then
		local pattern_esc = vim.pesc(search_text)
		for i, line in ipairs(preview_lines) do
			local content_start = line:find("│")
			if content_start then
				-- Content starts at content_start + 4 (after "│ " - 3 bytes for │ + 1 space)
				local content_offset = content_start + 3
				local is_matched_line = (i == matched_line_idx)

				-- Search directly in the display line starting from where content begins
				local search_start = content_offset + 1
				while true do
					local match_start, match_end = line:find(pattern_esc, search_start)
					if not match_start then
						break
					end

					-- Check if this is the specific match at result.col
					-- Convert display position back to original line column
					local col_in_original = match_start - content_offset
					local is_the_match = is_matched_line and (col_in_original == result.col)

					vim.api.nvim_buf_add_highlight(
						preview_buf,
						ns,
						is_the_match and "IncSearch" or "Search",
						i - 1,
						match_start - 1,
						match_end
					)

					search_start = match_end + 1
				end
			end
		end
	end

	-- Center the matched line in the preview window
	if preview_win and matched_line_idx then
		vim.api.nvim_win_set_cursor(preview_win, { matched_line_idx, 0 })
		vim.api.nvim_win_call(preview_win, function()
			vim.cmd("normal! zz")
		end)
	end
end

return M
