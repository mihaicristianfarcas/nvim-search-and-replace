-- UI module - main coordinator for search and replace interface
local M = {}

local search = require("nvim-search-and-replace.search")
local help = require("nvim-search-and-replace.help")
local preview = require("nvim-search-and-replace.preview")
local results = require("nvim-search-and-replace.results")
local windows = require("nvim-search-and-replace.windows")
local keymaps = require("nvim-search-and-replace.keymaps")
local replacer = require("nvim-search-and-replace.replace")
local uv = vim.loop

-- UI state
local state = {
	search_text = "",
	replace_text = "",
	results = {},
	truncated = false, -- whether results were capped at max_results
	selected_idx = 1,
	selected_items = {},
	searching = false,
	debounce_timer = nil,
	last_cursor_update = 0, -- throttles preview updates during cursor movement

	-- buffer handles
	search_buf = nil,
	replace_buf = nil,
	results_buf = nil,
	preview_buf = nil,

	-- Window handles
	search_win = nil,
	replace_win = nil,
	results_win = nil,
	preview_win = nil,
	last_preview_sig = nil,
}

local function update_preview()
	local result = state.results[state.selected_idx]
	local sig
	if result then
		sig = (result.filename or "")
			.. ":"
			.. tostring(result.lnum or 0)
			.. ":"
			.. tostring(result.col or 0)
			.. ":"
			.. (state.search_text or "")
			.. ":"
			.. (state.replace_text or "")
	else
		sig = "no-result"
	end

	if state.last_preview_sig == sig then
		return
	end

	state.last_preview_sig = sig
	local config = require("nvim-search-and-replace").get_config()
	preview.update(state.preview_buf, result, state.search_text, state.replace_text, config.smart_case)
end

local function update_results_list()
	local config = require("nvim-search-and-replace").get_config()
	results.update(
		state.results_buf,
		state.results,
		state.selected_idx,
		state.selected_items,
		state.search_text,
		config.smart_case
	)
end

local function do_search(opts)
	opts = opts or {}
	state.search_text = vim.api.nvim_buf_get_lines(state.search_buf, 0, -1, false)[1] or ""

	if state.searching then
		search.stop_search()
	end

	state.searching = true
	state.truncated = false
	windows.update_search_title(state.search_win, true)

	-- reset state for new search
	local new_results = {}
	local new_selected_idx = 1
	local new_selected_items = {}
	local last_update_time = 0
	local last_notify_time = 0
	local pending_update = false

	local config = require("nvim-search-and-replace").get_config()

	search.run_ripgrep_async(state.search_text, {
		max_results = config.max_results,
		max_file_size = config.max_file_size,
		smart_case = config.smart_case,
		multiline = config.multiline,
		sort = config.sort,
	}, function(batch, total_count, truncated)
		-- add new results to accumulator
		for _, result in ipairs(batch) do
			table.insert(new_results, result)
		end
		
		-- throttle UI updates to every 50ms to avoid blocking
		local now = vim.loop.now()
		if not pending_update and (now - last_update_time) > 50 then
			pending_update = true
			last_update_time = now
			
			vim.schedule(function()
				pending_update = false
				state.results = new_results
				state.selected_idx = new_selected_idx
				state.selected_items = new_selected_items
				
				-- use incremental rendering
				update_results_list()
				
				if state.selected_idx <= #state.results then
					update_preview()
				end
				
				-- update results title every 150ms
				if (now - last_notify_time) > 150 then
					last_notify_time = now
					windows.update_results_title(state.results_win, #new_results, truncated)
				end
			end)
		end
	end, function(final_results, exit_code, truncated, regex_error)
		state.searching = false
		windows.update_search_title(state.search_win, false, regex_error)

		-- Use final_results from search module as authoritative source
		state.results = final_results
		state.truncated = truncated or false
		state.selected_idx = #final_results > 0 and 1 or 0
		state.selected_items = {}
		state.last_preview_sig = nil
		update_results_list()
		update_preview()
		
		-- Update title with final count
		windows.update_results_title(state.results_win, #final_results, truncated)

		-- Suppress notifications if requested (e.g., after undo/redo)
		if not opts.silent then
			-- Show regex error if present
			if regex_error then
				vim.notify("Regex error: " .. regex_error, vim.log.levels.WARN)
			else
				exit_code = exit_code or 0
				
				-- Exit code 143 is SIGTERM (normal when stopping search), 1 is no results found
				if exit_code ~= 0 and exit_code ~= 1 and exit_code ~= 143 then
					vim.notify("Search terminated (exit code: " .. tostring(exit_code) .. ")", vim.log.levels.WARN)
				elseif exit_code ~= 143 then
					if #final_results == 0 then
						vim.notify("No results found", vim.log.levels.INFO)
					end
				end
			end
		end

		if state.results_win and vim.api.nvim_win_is_valid(state.results_win) and #final_results > 0 then
			vim.api.nvim_win_set_cursor(state.results_win, { 1, 0 })
		end
	end)
end

-- debounces search by 300ms to avoid excessive searches while typing
local function debounced_search()
	-- cancel any pending search
	if state.debounce_timer then
		vim.fn.timer_stop(state.debounce_timer)
		state.debounce_timer = nil
	end

	-- schedule new search with configurable debounce
	local plugin_config = require("nvim-search-and-replace").get_config()
	local debounce_ms = plugin_config.debounce_ms or 300
	state.debounce_timer = vim.fn.timer_start(debounce_ms, function()
		state.debounce_timer = nil
		do_search()
	end)
end

-- undoes last replacement and refreshes results (silent to preserve undo notification)
local function undo_action()
	replacer.undo_last()
	do_search({ silent = true })
end

-- redoes last undone replacement and refreshes results (silent to preserve redo notification)
local function redo_action()
	replacer.redo_last()
	do_search({ silent = true })
end

-- updates preview when cursor moves in results list (throttled to 50ms)
local function update_cursor_preview()
	-- throttle rapid cursor movements (90% fewer preview updates)
	local now = uv.now()
	if now - state.last_cursor_update < 50 then
		return -- skip if updated within last 50ms
	end
	state.last_cursor_update = now

	if state.results_win and vim.api.nvim_win_is_valid(state.results_win) then
		local cursor_pos = vim.api.nvim_win_get_cursor(state.results_win)
		if state.selected_idx ~= cursor_pos[1] then
			state.selected_idx = cursor_pos[1]
			update_preview()
		end
	end
end

-- replaces current item or visual selection in results list
local function replace_selected()
	local items_to_replace = {}

	-- Get visual selection range if in visual mode
	local mode = vim.api.nvim_get_mode().mode
	if mode:match("[vV]") then
		-- Get visual selection range
		local start_pos = vim.fn.getpos("v")
		local end_pos = vim.fn.getpos(".")
		local start_line = math.min(start_pos[2], end_pos[2])
		local end_line = math.max(start_pos[2], end_pos[2])

		for i = start_line, end_line do
			if state.results[i] then
				table.insert(items_to_replace, state.results[i])
			end
		end

		-- Exit visual mode
		vim.cmd("normal! \x1b")
	else
		-- Single item at cursor
		local cursor_pos = vim.api.nvim_win_get_cursor(state.results_win)
		local idx = cursor_pos[1]
		if state.results[idx] then
			items_to_replace = { state.results[idx] }
		end
	end

	if #items_to_replace > 0 then
		state.replace_text = vim.api.nvim_buf_get_lines(state.replace_buf, 0, -1, false)[1] or ""
		local summary = replacer.apply(items_to_replace, state.search_text, state.replace_text)
		replacer.notify_summary(summary)
		do_search()
	end
end

-- replaces all matches across all files and closes the interface
local function replace_all()
	-- When results were capped at max_results, "Replace ALL" can only touch the
	-- loaded subset. Make that explicit so the user isn't misled into thinking
	-- every match in the project was replaced.
	if state.truncated then
		local choice = vim.fn.confirm(
			string.format(
				"Results were truncated at %d matches; more exist that aren't loaded.\nReplace only the %d loaded matches?",
				#state.results,
				#state.results
			),
			"&Replace loaded\n&Cancel",
			2,
			"Warning"
		)
		if choice ~= 1 then
			return
		end
	end

	state.replace_text = vim.api.nvim_buf_get_lines(state.replace_buf, 0, -1, false)[1] or ""
	local summary = replacer.apply(state.results, state.search_text, state.replace_text)
	replacer.notify_summary(summary)
	M.close()
end

-- opens the selected result file at the matched location
local function open_in_file()
	-- trust the cursor position in the results window if available
	if state.results_win and vim.api.nvim_win_is_valid(state.results_win) then
		local cursor_pos = vim.api.nvim_win_get_cursor(state.results_win)
		state.selected_idx = math.max(cursor_pos[1], 1)
	end

	local result = state.results[state.selected_idx]
	if not result then
		vim.notify("No result selected to open.", vim.log.levels.WARN)
		return
	end

	-- close ui before opening the target file so it opens in a normal window
	M.close()

	local escaped = vim.fn.fnameescape(result.filename)
	vim.cmd(string.format("edit +%d %s", result.lnum, escaped))
	pcall(vim.api.nvim_win_set_cursor, 0, { result.lnum, math.max(result.col - 1, 0) })
	vim.cmd("normal! zz")
end

-- updates preview when replace text changes
local function update_preview_text()
	state.replace_text = vim.api.nvim_buf_get_lines(state.replace_buf, 0, -1, false)[1] or ""
	update_preview()
end

-- creates all buffers and windows for the ui
local function create_ui()
	-- create buffers
	local buffers = windows.create_buffers(state.search_text, state.replace_text)
	state.search_buf = buffers.search
	state.replace_buf = buffers.replace
	state.results_buf = buffers.results
	state.preview_buf = buffers.preview

	-- create layout and windows
	local layout = windows.create_layout()
	local wins = windows.create_windows(layout, buffers)
	state.search_win = wins.search
	state.replace_win = wins.replace
	state.results_win = wins.results
	state.preview_win = wins.preview
end

-- sets up all keyboard shortcuts and event handlers
local function setup_keymaps_internal()
	local callbacks = {
		show_help = help.show,
		stop_search = function()
			if state.debounce_timer then
				vim.fn.timer_stop(state.debounce_timer)
				state.debounce_timer = nil
			end
			search.stop_search()
			state.searching = false
			windows.update_search_title(state.search_win, false)
			vim.notify("Search stopped", vim.log.levels.INFO)
		end,
		close = M.close,
		undo = undo_action,
		redo = redo_action,
		update_cursor_preview = update_cursor_preview,
		replace_selected = replace_selected,
		replace_all = replace_all,
		open_in_file = open_in_file,
		do_search = debounced_search,
		update_preview_text = update_preview_text,
	}

	keymaps.setup(state, callbacks)
end

-- opens the search and replace interface
function M.open(opts)
	opts = opts or {}

	-- The UI state is a singleton; if an instance is already open, tear it down
	-- first so we don't orphan its windows/buffers and the new options apply.
	if state.search_win and vim.api.nvim_win_is_valid(state.search_win) then
		M.close()
	end

	state.search_text = opts.search or ""
	state.replace_text = opts.replace or ""
	state.selected_items = {}

	create_ui()
	setup_keymaps_internal()

	-- if search text was provided, perform initial search
	if state.search_text ~= "" then
		do_search()
	end

	-- start in insert mode in search field
	vim.api.nvim_set_current_win(state.search_win)
	vim.cmd("startinsert")
end

-- closes the interface and cleans up resources
function M.close()
	if state.debounce_timer then
		vim.fn.timer_stop(state.debounce_timer)
		state.debounce_timer = nil
	end

	search.stop_search()
	help.close()
	keymaps.cleanup()

	for _, win in ipairs({ state.search_win, state.replace_win, state.results_win, state.preview_win }) do
		if win and vim.api.nvim_win_is_valid(win) then
			pcall(vim.api.nvim_win_close, win, true)
		end
	end

	state.search_win = nil
	state.replace_win = nil
	state.results_win = nil
	state.preview_win = nil
	state.searching = false
end

return M
