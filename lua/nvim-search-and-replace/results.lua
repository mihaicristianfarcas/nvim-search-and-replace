-- Results module - handles results list display and highlighting
local M = {}

function M.update(results_buf, results, selected_idx, selected_items, search_text)
	if not results_buf or not vim.api.nvim_buf_is_valid(results_buf) then
		return
	end

	-- Make buffer modifiable temporarily
	vim.api.nvim_buf_set_option(results_buf, "modifiable", true)

	local cwd = vim.loop.cwd()
	local lines = {}
	for i, result in ipairs(results) do
		-- Convert to relative path
		local rel_path = result.filename
		if rel_path:sub(1, #cwd) == cwd then
			rel_path = rel_path:sub(#cwd + 2)
		end

		local display =
			string.format("%s:%d:%d: %s", rel_path, result.lnum, result.col, result.text:sub(1, 60))
		table.insert(lines, display)
	end

	if #lines == 0 then
		lines = { "No results" }
	end

	vim.api.nvim_buf_set_lines(results_buf, 0, -1, false, lines)

	-- Set back to non-modifiable
	vim.api.nvim_buf_set_option(results_buf, "modifiable", false)

	-- Add syntax highlighting for results
	local ns = vim.api.nvim_create_namespace("nvim_search_and_replace_selection")
	vim.api.nvim_buf_clear_namespace(results_buf, ns, 0, -1)
	
	for i, result in ipairs(results) do
		local line_idx = i - 1
		local line = lines[i]
		if line then
			-- Highlight filename (before first colon)
			local filename_end = line:find(":")
			if filename_end then
				vim.api.nvim_buf_add_highlight(results_buf, ns, "Directory", line_idx, 0, filename_end - 1)

				-- Highlight line:col numbers
				local second_colon = line:find(":", filename_end + 1)
				if second_colon then
					local third_colon = line:find(":", second_colon + 1)
					if third_colon then
						vim.api.nvim_buf_add_highlight(
							results_buf,
							ns,
							"LineNr",
							line_idx,
							filename_end,
							third_colon
						)

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
				end
			end
		end
	end
end

return M
