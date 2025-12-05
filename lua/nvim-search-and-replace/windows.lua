-- Windows module - handles window creation and layout
local M = {}
local config = require("nvim-search-and-replace.config")

function M.create_layout()
	-- Layout (80% of screen)
	local width = vim.o.columns
	local height = vim.o.lines - 2

	local ui_width = math.floor(width * 0.8)
	local ui_height = math.floor(height * 0.8)
	local start_col = math.floor((width - ui_width) / 2)
	local start_row = math.floor((height - ui_height) / 2)

	local left_width = math.floor(ui_width * 0.5)
	local right_width = ui_width - left_width

	return {
		ui_width = ui_width,
		ui_height = ui_height,
		start_col = start_col,
		start_row = start_row,
		left_width = left_width,
		right_width = right_width,
	}
end

function M.create_windows(layout, buffers, use_regex)
	local windows = {}

	-- Search input (top left)
	local search_title = use_regex and " Search (Regex) " or " Search (Literal) "
	windows.search = vim.api.nvim_open_win(buffers.search, true, {
		relative = "editor",
		width = layout.left_width - 2,
		height = 1,
		row = layout.start_row,
		col = layout.start_col,
		style = "minimal",
		border = "rounded",
		title = search_title,
		title_pos = "center",
	})

	-- Replace input (below search)
	windows.replace = vim.api.nvim_open_win(buffers.replace, false, {
		relative = "editor",
		width = layout.left_width - 2,
		height = 1,
		row = layout.start_row + 3,
		col = layout.start_col,
		style = "minimal",
		border = "rounded",
		title = " Replace ",
		title_pos = "center",
	})

	-- Results list (below replace)
	local kb = config.keybindings
	local help_keys = config.format_keys(kb.help.keys)
	windows.results = vim.api.nvim_open_win(buffers.results, false, {
		relative = "editor",
		width = layout.left_width - 2,
		height = layout.ui_height - 8,
		row = layout.start_row + 6,
		col = layout.start_col,
		style = "minimal",
		border = "rounded",
		title = " Results (Press " .. help_keys .. " for help) ",
		title_pos = "center",
	})

	-- Preview (right side)
	windows.preview = vim.api.nvim_open_win(buffers.preview, false, {
		relative = "editor",
		width = layout.right_width - 2,
		height = layout.ui_height - 2,
		row = layout.start_row,
		col = layout.start_col + layout.left_width,
		style = "minimal",
		border = "rounded",
		title = " Preview ",
		title_pos = "center",
	})

	-- Set window options
	vim.api.nvim_win_set_option(windows.search, "wrap", false)
	vim.api.nvim_win_set_option(windows.replace, "wrap", false)
	vim.api.nvim_win_set_option(windows.results, "cursorline", true)
	vim.api.nvim_win_set_option(windows.results, "wrap", false)
	vim.api.nvim_win_set_option(windows.preview, "wrap", true)

	return windows
end

function M.update_search_title(search_win, use_regex, searching)
	if search_win and vim.api.nvim_win_is_valid(search_win) then
		local mode = use_regex and "Regex" or "Literal"
		local status = searching and " [Searching...] " or " "
		local title = " Search (" .. mode .. ")" .. status
		vim.api.nvim_win_set_config(search_win, { title = title })
	end
end

function M.create_buffers(search_text, replace_text)
	local buffers = {}

	buffers.search = vim.api.nvim_create_buf(false, true)
	buffers.replace = vim.api.nvim_create_buf(false, true)
	buffers.results = vim.api.nvim_create_buf(false, true)
	buffers.preview = vim.api.nvim_create_buf(false, true)

	vim.api.nvim_buf_set_lines(buffers.search, 0, -1, false, { search_text })
	vim.api.nvim_buf_set_lines(buffers.replace, 0, -1, false, { replace_text })

	-- Set buffer options
	for _, buf in ipairs({ buffers.search, buffers.replace }) do
		vim.api.nvim_buf_set_option(buf, "buftype", "")
		vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
		vim.api.nvim_buf_set_option(buf, "modifiable", true)
		vim.api.nvim_buf_set_option(buf, "textwidth", 0)
	end

	vim.api.nvim_buf_set_option(buffers.results, "buftype", "nofile")
	vim.api.nvim_buf_set_option(buffers.results, "modifiable", false)
	vim.api.nvim_buf_set_option(buffers.results, "wrap", false)
	vim.api.nvim_buf_set_option(buffers.preview, "buftype", "nofile")
	vim.api.nvim_buf_set_option(buffers.preview, "modifiable", false)

	return buffers
end

return M
