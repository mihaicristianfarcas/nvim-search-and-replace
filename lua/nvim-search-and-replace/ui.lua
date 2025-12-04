-- UI module - main coordinator for search and replace interface
local M = {}

local search = require("nvim-search-and-replace.search")
local help = require("nvim-search-and-replace.help")
local preview = require("nvim-search-and-replace.preview")
local results = require("nvim-search-and-replace.results")
local windows = require("nvim-search-and-replace.windows")
local keymaps = require("nvim-search-and-replace.keymaps")
local replacer = require("nvim-search-and-replace.replace")

-- UI state
local state = {
	search_text = "",
	replace_text = "",
	results = {},
	selected_idx = 1,
	selected_items = {},
	use_regex = false,
	searching = false,
	debounce_timer = nil,

	-- Buffer handles
	search_buf = nil,
	replace_buf = nil,
	results_buf = nil,
	preview_buf = nil,

	-- Window handles
	search_win = nil,
	replace_win = nil,
	results_win = nil,
	preview_win = nil,
}

local function update_preview()
	local result = state.results[state.selected_idx]
	preview.update(state.preview_buf, result, state.search_text, state.replace_text, state.use_regex)
end

local function update_results_list()
	results.update(state.results_buf, state.results, state.selected_idx, state.selected_items, state.search_text)
end

local function do_search()
	state.search_text = vim.api.nvim_buf_get_lines(state.search_buf, 0, -1, false)[1] or ""
	
	if state.searching then
		search.stop_search()
	end
	
	state.searching = true
	windows.update_search_title(state.search_win, state.use_regex, true)
	
	local new_results = {}
	local new_selected_idx = 1
	local new_selected_items = {}
	
	local config = require("nvim-search-and-replace").get_config()
	
	search.run_ripgrep_async(
		state.search_text, 
		{ 
			literal = not state.use_regex,
			max_results = config.max_results
		},
		function(batch, total_count, truncated)
			for _, result in ipairs(batch) do
				table.insert(new_results, result)
			end
			state.results = new_results
			state.selected_idx = new_selected_idx
			state.selected_items = new_selected_items
			update_results_list()
			if state.selected_idx <= #state.results then
				update_preview()
			end
		end,
		function(final_results, exit_code, truncated)
			state.searching = false
			windows.update_search_title(state.search_win, state.use_regex, false)
			
			-- Use final_results from search module as authoritative source
			state.results = final_results
			state.selected_idx = #final_results > 0 and 1 or 0
			state.selected_items = {}
			update_results_list()
			update_preview()
			
			exit_code = exit_code or 0
			-- Exit code 143 is SIGTERM (normal when stopping search), 1 is no results found
			if exit_code ~= 0 and exit_code ~= 1 and exit_code ~= 143 then
				vim.notify("Search terminated (exit code: " .. tostring(exit_code) .. ")", vim.log.levels.WARN)
			elseif exit_code ~= 143 then
				if #final_results == 0 then
					vim.notify("No results found", vim.log.levels.INFO)
				else
					local msg = string.format("Found %d matches", #final_results)
					if truncated then
						msg = msg .. " (truncated - too many results)"
					end
					vim.notify(msg, truncated and vim.log.levels.WARN or vim.log.levels.INFO)
				end
			end
			
			if state.results_win and vim.api.nvim_win_is_valid(state.results_win) and #final_results > 0 then
				vim.api.nvim_win_set_cursor(state.results_win, {1, 0})
			end
		end
	)
end

local function debounced_search()
	-- Cancel any pending search
	if state.debounce_timer then
		vim.fn.timer_stop(state.debounce_timer)
		state.debounce_timer = nil
	end
	
	-- Schedule new search
	state.debounce_timer = vim.fn.timer_start(300, function()
		state.debounce_timer = nil
		do_search()
	end)
end

local function toggle_regex()
	state.use_regex = not state.use_regex
	windows.update_search_title(state.search_win, state.use_regex)
	vim.notify(state.use_regex and "Regex mode enabled" or "Literal mode enabled", vim.log.levels.INFO)
	do_search()
end

local function undo_action()
	replacer.undo_last()
	do_search()
end

local function redo_action()
	replacer.redo_last()
	do_search()
end

local function update_cursor_preview()
	if state.results_win and vim.api.nvim_win_is_valid(state.results_win) then
		local cursor_pos = vim.api.nvim_win_get_cursor(state.results_win)
		state.selected_idx = cursor_pos[1]
		update_preview()
	end
end

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
		local summary = replacer.apply(items_to_replace, state.search_text, state.replace_text, { literal = not state.use_regex })
		replacer.notify_summary(summary)
		do_search()
	end
end

local function replace_all()
	state.replace_text = vim.api.nvim_buf_get_lines(state.replace_buf, 0, -1, false)[1] or ""
	local summary = replacer.apply(state.results, state.search_text, state.replace_text, { literal = not state.use_regex })
	replacer.notify_summary(summary)
	M.close()
end

local function update_preview_text()
	state.replace_text = vim.api.nvim_buf_get_lines(state.replace_buf, 0, -1, false)[1] or ""
	update_preview()
end

local function create_ui()
	-- Create buffers
	local buffers = windows.create_buffers(state.search_text, state.replace_text)
	state.search_buf = buffers.search
	state.replace_buf = buffers.replace
	state.results_buf = buffers.results
	state.preview_buf = buffers.preview

	-- Create layout and windows
	local layout = windows.create_layout()
	local wins = windows.create_windows(layout, buffers, state.use_regex)
	state.search_win = wins.search
	state.replace_win = wins.replace
	state.results_win = wins.results
	state.preview_win = wins.preview
end

local function setup_keymaps_internal()
	local callbacks = {
		show_help = help.show,
		toggle_regex = toggle_regex,
		stop_search = function()
			if state.debounce_timer then
				vim.fn.timer_stop(state.debounce_timer)
				state.debounce_timer = nil
			end
			search.stop_search()
			state.searching = false
			windows.update_search_title(state.search_win, state.use_regex, false)
			vim.notify("Search stopped", vim.log.levels.INFO)
		end,
		close = M.close,
		undo = undo_action,
		redo = redo_action,
		update_cursor_preview = update_cursor_preview,
		replace_selected = replace_selected,
		replace_all = replace_all,
		do_search = debounced_search,
		update_preview_text = update_preview_text,
	}
	
	keymaps.setup(state, callbacks)
end

function M.open(opts)
	opts = opts or {}
	state.search_text = opts.search or ""
	state.replace_text = opts.replace or ""
	state.use_regex = opts.use_regex or false
	state.selected_items = {}

	create_ui()
	setup_keymaps_internal()

	-- If search text was provided, perform initial search
	if state.search_text ~= "" then
		do_search()
	end

	-- Start in insert mode in search field
	vim.api.nvim_set_current_win(state.search_win)
	vim.cmd("startinsert")
end

function M.close()
	if state.debounce_timer then
		vim.fn.timer_stop(state.debounce_timer)
		state.debounce_timer = nil
	end
	
	search.stop_search()
	help.close()

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
