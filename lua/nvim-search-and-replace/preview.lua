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

	local lnum = result.lnum
	local context_before = 20
	local context_after = 20
	local start_line = math.max(1, lnum - context_before)
	local end_line = math.min(#file_lines, lnum + context_after)

	local preview_lines = {}
	local before_line_idx = nil
	local after_line_idx = nil

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
		local prefix = string.format("%4d │ ", i)

		if i == lnum and replace_text ~= "" then
			-- Show the change
			local new_line =
				replacer.compute_line(line, result.col, search_text, replace_text, { literal = not use_regex })

			table.insert(preview_lines, "")
			table.insert(preview_lines, "      BEFORE:")
			before_line_idx = #preview_lines + 1
			table.insert(preview_lines, prefix .. line)
			table.insert(preview_lines, "      AFTER:")
			after_line_idx = #preview_lines + 1
			table.insert(preview_lines, prefix .. (new_line or line))
			table.insert(preview_lines, "")
		else
			table.insert(preview_lines, prefix .. line)
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

	-- Highlight the search term in the preview
	if search_text ~= "" then
		for i, line in ipairs(preview_lines) do
			local match_start = line:find(vim.pesc(search_text))
			if match_start then
				vim.api.nvim_buf_add_highlight(
					preview_buf,
					ns,
					"Search",
					i - 1,
					match_start - 1,
					match_start - 1 + #search_text
				)
			end
		end
	end
end

return M
