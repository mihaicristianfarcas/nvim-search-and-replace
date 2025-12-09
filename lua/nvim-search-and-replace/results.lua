-- Results module - handles results list display and highlighting
local M = {}

local RENDER_CHUNK_SIZE = 200 -- render in chunks to avoid blocking UI
local HIGHLIGHT_CHUNK_SIZE = 500 -- apply highlights in chunks
local MAX_TEXT_DISPLAY = 120 -- limit displayed text length per result

-- updates results list buffer with search matches
-- supports incremental updates for better performance
-- start_idx controls incremental updates: 1 = full redraw, >1 = append-only
function M.update(results_buf, results, selected_idx, selected_items, search_text, start_idx, smart_case, use_regex)
	if not results_buf or not vim.api.nvim_buf_is_valid(results_buf) then
		return
	end

	if not results then
		results = {}
	end

	start_idx = start_idx or 1
	search_text = search_text or ""
	smart_case = smart_case ~= false  -- default to true
	use_regex = use_regex or false  -- default to literal mode

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
		-- truncate long text to prevent UI blocking
		local text = result.text or ""
		if #text > MAX_TEXT_DISPLAY then
			text = text:sub(1, MAX_TEXT_DISPLAY) .. "..."
		end
		new_lines[#new_lines + 1] =
			string.format("%s:%d:%d: %s", rel_path, result.lnum, result.col, text)
	end

	-- if this is the first batch or there are no results, refresh the whole buffer
	local full_refresh = (start_idx == 1)
	if #results == 0 then
		full_refresh = true
		new_lines = { "No results" }
	end

	vim.bo[results_buf].modifiable = true

	-- split buffer operations into chunks to avoid blocking
	local function set_lines_chunked(buf, start_line, end_line, lines, callback)
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
			
			if full_refresh and processed == 0 then
				pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, chunk)
			else
				local insert_pos = start_line + processed
				pcall(vim.api.nvim_buf_set_lines, buf, insert_pos, insert_pos, false, chunk)
			end
			
			processed = chunk_end
			
			if processed < total then
				-- continue processing in next event loop tick
				vim.schedule(process_chunk)
			else
				-- done with lines, start highlighting
				if callback then
					callback()
				end
			end
		end
		
		process_chunk()
	end

	local insert_at = full_refresh and 0 or (start_idx - 1)
	
	if full_refresh then
		pcall(vim.api.nvim_buf_clear_namespace, results_buf, ns, 0, -1)
	end

	set_lines_chunked(results_buf, insert_at, insert_at, new_lines, function()
		vim.bo[results_buf].modifiable = false
		
		-- apply highlights in chunks to avoid blocking
		M.apply_highlights_async(results_buf, new_lines, search_text, full_refresh and 0 or insert_at, ns, smart_case, use_regex)
	end)
end

-- apply highlights asynchronously in chunks
function M.apply_highlights_async(results_buf, lines, search_text, base_idx, ns, smart_case, use_regex)
	if not vim.api.nvim_buf_is_valid(results_buf) then
		return
	end
	
	smart_case = smart_case ~= false  -- default to true
	use_regex = use_regex or false  -- default to literal
	local highlights = {}
	
	-- determine if search should be case-insensitive (only for literal mode)
	local case_insensitive = not use_regex and smart_case and search_text == search_text:lower()
	
	-- collect all highlight positions
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
			local search_in = line:sub(third_colon + 1)
			
			if use_regex then
				-- regex mode: use vim regex for highlighting
				local ok, matches = pcall(vim.fn.matchstrpos, search_in, search_text)
				if ok and matches[2] ~= -1 then
					local abs_start = third_colon + matches[2] + 1
					table.insert(highlights, {
						group = "Search",
						line = line_idx,
						col_start = abs_start - 1,
						col_end = abs_start - 1 + #matches[1],
					})
				end
			elseif case_insensitive then
				-- literal case-insensitive
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
				-- literal case-sensitive
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
		collect_highlights(line, base_idx + i - 1)
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
