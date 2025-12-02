-- Help module - manages help popup window
local M = {}
local config = require("nvim-search-and-replace.config")

local state = {
	help_buf = nil,
	help_win = nil,
}

function M.show()
	-- Close help if already open
	if state.help_win and vim.api.nvim_win_is_valid(state.help_win) then
		vim.api.nvim_win_close(state.help_win, true)
		state.help_win = nil
		state.help_buf = nil
		return
	end

	-- Create help buffer
	state.help_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_option(state.help_buf, "buftype", "nofile")
	vim.api.nvim_buf_set_option(state.help_buf, "modifiable", false)

	-- Get help lines from config
	local help_lines = config.get_help_lines()

	vim.api.nvim_buf_set_option(state.help_buf, "modifiable", true)
	vim.api.nvim_buf_set_lines(state.help_buf, 0, -1, false, help_lines)
	vim.api.nvim_buf_set_option(state.help_buf, "modifiable", false)

	-- Calculate popup size and position (centered)
	local width = 70
	local height = #help_lines
	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)

	-- Create floating window
	local kb = config.keybindings
	local close_keys = config.format_keys(kb.help.keys)
	state.help_win = vim.api.nvim_open_win(state.help_buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		style = "minimal",
		border = "rounded",
		title = " Help - Press " .. close_keys .. " to close ",
		title_pos = "center",
	})

	-- Disable insert in help window
	vim.api.nvim_buf_set_option(state.help_buf, "modifiable", false)
	vim.api.nvim_buf_set_option(state.help_buf, "readonly", true)
	
	-- Force normal mode when entering the help window
	vim.api.nvim_create_autocmd({"BufEnter", "WinEnter"}, {
		buffer = state.help_buf,
		callback = function()
			vim.cmd("stopinsert")
		end,
	})

	-- Add syntax highlighting
	local ns = vim.api.nvim_create_namespace("nvim_search_and_replace_help")
	vim.api.nvim_buf_add_highlight(state.help_buf, ns, "Title", 1, 0, -1)
	
	for i = 3, #help_lines - 1 do
		local line = help_lines[i]
		if line:match("^  %u") then
			-- Section headers
			vim.api.nvim_buf_add_highlight(state.help_buf, ns, "Special", i - 1, 0, -1)
		elseif line:match("^    ") then
			-- Keybinding lines - highlight the key portion
			local dash_pos = line:find(" - ")
			if dash_pos then
				vim.api.nvim_buf_add_highlight(state.help_buf, ns, "Keyword", i - 1, 4, dash_pos - 1)
			end
		end
	end

	-- Close help on configured keys
	local function close_help()
		if state.help_win and vim.api.nvim_win_is_valid(state.help_win) then
			vim.api.nvim_win_close(state.help_win, true)
			state.help_win = nil
			state.help_buf = nil
		end
	end

	-- Map all help toggle keys to close
	for _, key in ipairs(kb.help.keys) do
		vim.keymap.set("n", key, close_help, { buffer = state.help_buf, noremap = true, silent = true })
	end
	
	-- Map all close keys
	for _, key in ipairs(kb.close.keys) do
		vim.keymap.set("n", key, close_help, { buffer = state.help_buf, noremap = true, silent = true })
	end
end

function M.close()
	if state.help_win and vim.api.nvim_win_is_valid(state.help_win) then
		pcall(vim.api.nvim_win_close, state.help_win, true)
		state.help_win = nil
		state.help_buf = nil
	end
end

function M.is_open()
	return state.help_win and vim.api.nvim_win_is_valid(state.help_win)
end

return M
