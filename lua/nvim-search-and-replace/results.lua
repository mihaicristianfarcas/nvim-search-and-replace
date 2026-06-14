-- Results module - handles results list display and highlighting
-- Uses ripgrep JSON output for precise match highlighting
-- Implements chunked rendering and highlighting for responsive UI with large result sets
local M = {}

local RENDER_CHUNK_SIZE = 200   -- Render in chunks to avoid blocking UI
local HIGHLIGHT_CHUNK_SIZE = 500 -- Apply highlights in chunks
local MAX_TEXT_DISPLAY = 120     -- Limit displayed text length per result

-- Updates results list buffer with search matches.
-- The buffer is fully refreshed on each call; lines and highlights are written in
-- chunks across event-loop ticks so large result sets don't block the UI.
function M.update(results_buf, results, selected_idx, selected_items, search_text, smart_case)
	if not results_buf or not vim.api.nvim_buf_is_valid(results_buf) then
		return
	end

	if not results then
		results = {}
	end

	search_text = search_text or ""
	smart_case = smart_case ~= false  -- Default to true

	local cwd = vim.loop.cwd()
	local ns = vim.api.nvim_create_namespace("nvim_search_and_replace_selection")

	-- Build the display line for every result
	local new_lines = {}
	for i = 1, #results do
		local result = results[i]
		local rel_path = result.filename
		if rel_path:sub(1, #cwd) == cwd then
			rel_path = rel_path:sub(#cwd + 2)
		end
		-- truncate long text to prevent UI blocking
		local text = result.text or ""
		if #text > MAX_TEXT_DISPLAY then
			text = text:sub(1, MAX_TEXT_DISPLAY) .. "..."
		end
		new_lines[#new_lines + 1] =
			string.format("%s:%d:%d: %s", rel_path, result.lnum, result.col, text)
	end

	if #results == 0 then
		new_lines = { "No results" }
	end

	vim.bo[results_buf].modifiable = true
	pcall(vim.api.nvim_buf_clear_namespace, results_buf, ns, 0, -1)

	-- Write the lines in chunks to avoid blocking on large result sets
	local function set_lines_chunked(buf, lines, callback)
		local total = #lines
		local processed = 0

		local function process_chunk()
			if not vim.api.nvim_buf_is_valid(buf) then
				return
			end

			local chunk_end = math.min(processed + RENDER_CHUNK_SIZE, total)
			local chunk = {}
			for i = processed + 1, chunk_end do
				chunk[#chunk + 1] = lines[i]
			end

			if processed == 0 then
				pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, chunk)
			else
				pcall(vim.api.nvim_buf_set_lines, buf, processed, processed, false, chunk)
			end

			processed = chunk_end

			if processed < total then
				vim.schedule(process_chunk)
			elseif callback then
				callback()
			end
		end

		process_chunk()
	end

	set_lines_chunked(results_buf, new_lines, function()
		vim.bo[results_buf].modifiable = false
		M.apply_highlights_async(results_buf, new_lines, results, search_text, 0, ns, smart_case)
	end)
end

-- Applies highlights asynchronously in chunks to avoid UI blocking
-- Uses exact match_text and match_len from ripgrep JSON output for precise highlighting
--
-- @param results_data: array of result objects with match_text and match_len fields
function M.apply_highlights_async(results_buf, lines, results_data, search_text, base_idx, ns, smart_case)
	if not vim.api.nvim_buf_is_valid(results_buf) then
		return
	end
	
	smart_case = smart_case ~= false  -- Default to true
	local highlights = {}
	
	-- Determine if search should be case-insensitive
	local case_insensitive = smart_case and search_text == search_text:lower()
	
	-- Collect all highlight positions
	local function collect_highlights(line, line_idx, result)
		-- highlight filename (before first colon)
		-- Parse the "<path>:<lnum>:<col>: " prefix. Matching the numeric
		-- :lnum:col: suffix (rather than the first colon) keeps Windows drive
		-- letters like C:\ as part of the path instead of splitting on them.
		local path, lnum_str, col_str = line:match("^(.-):(%d+):(%d+): ")
		if not path then
			return
		end
		local filename_end = #path + 1 -- position of the colon after the path
		local second_colon = filename_end + 1 + #lnum_str
		local third_colon = second_colon + 1 + #col_str

		table.insert(highlights, {
			group = "Directory",
			line = line_idx,
			col_start = 0,
			col_end = filename_end - 1,
		})

		table.insert(highlights, {
			group = "LineNr",
			line = line_idx,
			col_start = filename_end,
			col_end = third_colon,
		})

		-- highlight the matched text
		if search_text ~= "" then
			local search_in = line:sub(third_colon + 1)
			
			if result and result.match_text and result.match_len and result.col then
				-- Use exact match info from ripgrep JSON output
				-- The match is at result.col in the original line text
				-- We need to find it in search_in which starts after ": "
				local text_content_start = third_colon + 2  -- After ": "
				local match_pos_in_search = result.col
				local abs_start = text_content_start + match_pos_in_search - 1

				-- For multiline matches only the first physical line is displayed,
				-- so clamp the highlight to the end of the line to avoid overshooting.
				table.insert(highlights, {
					group = "Search",
					line = line_idx,
					col_start = abs_start - 1,
					col_end = math.min(abs_start - 1 + result.match_len, #line),
				})
			elseif case_insensitive then
				-- Case-insensitive
				local search_lower = search_text:lower()
				local line_lower = search_in:lower()
				local pos = 1
				
				while true do
					local match_start, match_end = line_lower:find(search_lower, pos, true)
					if not match_start then break end
					
					local abs_start = third_colon + match_start
					table.insert(highlights, {
						group = "Search",
						line = line_idx,
						col_start = abs_start - 1,
						col_end = abs_start - 1 + (match_end - match_start + 1),
					})
					pos = match_end + 1
				end
			else
				-- Case-sensitive
				local match_start = search_in:find(search_text, 1, true)
				if match_start then
					local abs_start = third_colon + match_start
					table.insert(highlights, {
						group = "Search",
						line = line_idx,
						col_start = abs_start - 1,
						col_end = abs_start - 1 + #search_text,
					})
				end
			end
		end
	end
	
	-- collect all highlights
	for i, line in ipairs(lines) do
		local result = results_data and results_data[i]
		collect_highlights(line, base_idx + i - 1, result)
	end
	
	-- apply highlights in chunks
	local processed = 0
	local total = #highlights
	
	local function apply_chunk()
		if not vim.api.nvim_buf_is_valid(results_buf) then
			return
		end
		
		local chunk_end = math.min(processed + HIGHLIGHT_CHUNK_SIZE, total)
		for i = processed + 1, chunk_end do
			local hl = highlights[i]
			pcall(vim.api.nvim_buf_add_highlight, results_buf, ns, hl.group, hl.line, hl.col_start, hl.col_end)
		end
		
		processed = chunk_end
		
		if processed < total then
			vim.schedule(apply_chunk)
		end
	end
	
	apply_chunk()
end

return M
