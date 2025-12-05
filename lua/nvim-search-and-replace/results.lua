-- Results module - handles results list display and highlighting
local M = {}

-- start_idx controls incremental updates: 1 = full redraw, >1 = append-only
function M.update(results_buf, results, selected_idx, selected_items, search_text, start_idx)
	if not results_buf or not vim.api.nvim_buf_is_valid(results_buf) then
		return
	end

	start_idx = start_idx or 1

	local cwd = vim.loop.cwd()
	local ns = vim.api.nvim_create_namespace("nvim_search_and_replace_selection")

	-- Build only the new lines that need to be written
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

	-- If this is the first batch or there are no results, refresh the whole buffer
	local full_refresh = (start_idx == 1)
	if #results == 0 then
		full_refresh = true
		new_lines = { "No results" }
	end

	vim.api.nvim_buf_set_option(results_buf, "modifiable", true)

	if full_refresh then
		vim.api.nvim_buf_set_lines(results_buf, 0, -1, false, new_lines)
		vim.api.nvim_buf_clear_namespace(results_buf, ns, 0, -1)
	else
		local insert_at = start_idx - 1
		vim.api.nvim_buf_set_lines(results_buf, insert_at, insert_at, false, new_lines)
	end

	vim.api.nvim_buf_set_option(results_buf, "modifiable", false)

	-- Add syntax highlighting for results
	local function highlight_line(line, line_idx)
		-- Highlight filename (before first colon)
		local filename_end = line:find(":")
		if not filename_end then
			return
		end

		vim.api.nvim_buf_add_highlight(results_buf, ns, "Directory", line_idx, 0, filename_end - 1)

		-- Highlight line:col numbers
		local second_colon = line:find(":", filename_end + 1)
		if not second_colon then
			return
		end
		local third_colon = line:find(":", second_colon + 1)
		if not third_colon then
			return
		end

		vim.api.nvim_buf_add_highlight(results_buf, ns, "LineNr", line_idx, filename_end, third_colon)

		-- Highlight the matched text
		if search_text ~= "" then
			local match_start = line:find(vim.pesc(search_text), third_colon)
			if match_start then
				vim.api.nvim_buf_add_highlight(
					results_buf,
					ns,
					"Search",
					line_idx,
					match_start - 1,
					match_start - 1 + #search_text
				)
			end
		end
	end

	if full_refresh then
		for i, line in ipairs(new_lines) do
			highlight_line(line, i - 1)
		end
	else
		local base_idx = start_idx - 1
		for i, line in ipairs(new_lines) do
			highlight_line(line, base_idx + i - 1)
		end
	end
end

return M
