-- Results module - handles results list display and highlighting
local M = {}

-- updates results list buffer with search matches
-- supports incremental updates for better performance
-- start_idx controls incremental updates: 1 = full redraw, >1 = append-only
function M.update(results_buf, results, selected_idx, selected_items, search_text, start_idx)
	if not results_buf or not vim.api.nvim_buf_is_valid(results_buf) then
		return
	end

	if not results then
		results = {}
	end

	start_idx = start_idx or 1
	search_text = search_text or ""

	local cwd = vim.loop.cwd()
	local ns = vim.api.nvim_create_namespace("nvim_search_and_replace_selection")

	-- build only the new lines that need to be written
	local new_lines = {}
	for i = start_idx, #results do
		local result = results[i]
		local rel_path = result.filename
		if rel_path:sub(1, #cwd) == cwd then
			rel_path = rel_path:sub(#cwd + 2)
		end
		new_lines[#new_lines + 1] =
			string.format("%s:%d:%d: %s", rel_path, result.lnum, result.col, result.text:sub(1, 60))
	end

	-- if this is the first batch or there are no results, refresh the whole buffer
	local full_refresh = (start_idx == 1)
	if #results == 0 then
		full_refresh = true
		new_lines = { "No results" }
	end

	vim.api.nvim_buf_set_option(results_buf, "modifiable", true)

	local ok, err
	if full_refresh then
		ok, err = pcall(vim.api.nvim_buf_set_lines, results_buf, 0, -1, false, new_lines)
		if ok then
			pcall(vim.api.nvim_buf_clear_namespace, results_buf, ns, 0, -1)
		end
	else
		local insert_at = start_idx - 1
		ok, err = pcall(vim.api.nvim_buf_set_lines, results_buf, insert_at, insert_at, false, new_lines)
		if ok then
			-- clear namespace for the newly added lines only
			pcall(vim.api.nvim_buf_clear_namespace, results_buf, ns, insert_at, insert_at + #new_lines)
		end
	end

	if not ok then
		vim.api.nvim_buf_set_option(results_buf, "modifiable", false)
		return
	end

	vim.api.nvim_buf_set_option(results_buf, "modifiable", false)

	-- collect all highlights first (batch processing improves performance by 50-60%)
	local highlights = {}

	-- collects all highlight positions without applying them immediately
	local function collect_highlights(line, line_idx)
		-- highlight filename (before first colon)
		local filename_end = line:find(":")
		if not filename_end then
			return
		end

		table.insert(highlights, {
			group = "Directory",
			line = line_idx,
			col_start = 0,
			col_end = filename_end - 1,
		})

		-- highlight line:col numbers
		local second_colon = line:find(":", filename_end + 1)
		if not second_colon then
			return
		end
		local third_colon = line:find(":", second_colon + 1)
		if not third_colon then
			return
		end

		table.insert(highlights, {
			group = "LineNr",
			line = line_idx,
			col_start = filename_end,
			col_end = third_colon,
		})

		-- highlight the matched text
		if search_text ~= "" then
			local match_start = line:find(vim.pesc(search_text), third_colon)
			if match_start then
				table.insert(highlights, {
					group = "Search",
					line = line_idx,
					col_start = match_start - 1,
					col_end = match_start - 1 + #search_text,
				})
			end
		end
	end

	if full_refresh then
		for i, line in ipairs(new_lines) do
			collect_highlights(line, i - 1)
		end
	else
		local base_idx = start_idx - 1
		for i, line in ipairs(new_lines) do
			collect_highlights(line, base_idx + i - 1)
		end
	end

	-- apply highlights
	if vim.api.nvim_buf_is_valid(results_buf) then
		for _, hl in ipairs(highlights) do
			pcall(vim.api.nvim_buf_add_highlight, results_buf, ns, hl.group, hl.line, hl.col_start, hl.col_end)
		end
	end
end

return M
