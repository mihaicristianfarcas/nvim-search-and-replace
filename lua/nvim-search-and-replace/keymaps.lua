-- Keymaps module - handles all keyboard mappings
local M = {}
local config = require("nvim-search-and-replace.config")

function M.setup(state, callbacks)
	local kb = config.keybindings
	
	local function map(buf, mode, key, fn)
		vim.keymap.set(mode, key, fn, { buffer = buf, noremap = true, silent = true })
	end

	-- Common keymaps for ALL buffers
	for _, buf in ipairs({ state.search_buf, state.replace_buf, state.results_buf, state.preview_buf }) do
		-- Show help
		for _, key in ipairs(kb.help.keys) do
			map(buf, { "n", "i" }, key, callbacks.show_help)
		end

		-- Toggle regex mode
		for _, key in ipairs(kb.toggle_regex.keys) do
			map(buf, { "n", "i" }, key, callbacks.toggle_regex)
		end

		-- Stop search
		for _, key in ipairs(kb.stop_search.keys) do
			map(buf, { "n", "i" }, key, callbacks.stop_search)
		end

		-- Close
		for _, key in ipairs(kb.close.keys) do
			map(buf, "n", key, callbacks.close)
		end
		map(buf, { "n", "i" }, "<C-c>", callbacks.close)

		-- Undo
		for _, key in ipairs(kb.undo.keys) do
			if key == "u" then
				map(buf, "n", key, callbacks.undo)
			else
				map(buf, { "n", "i" }, key, callbacks.undo)
			end
		end

		-- Redo
		for _, key in ipairs(kb.redo.keys) do
			map(buf, { "n", "i" }, key, callbacks.redo)
		end
	end

	-- Tab/Shift-Tab for navigation between input fields
	for _, buf in ipairs({ state.search_buf, state.replace_buf }) do
		map(buf, { "i", "n" }, "<Tab>", function()
			if vim.api.nvim_get_current_win() == state.search_win then
				vim.api.nvim_set_current_win(state.replace_win)
				vim.cmd("startinsert!")
			elseif vim.api.nvim_get_current_win() == state.replace_win then
				vim.api.nvim_set_current_win(state.results_win)
				vim.cmd("stopinsert")
			end
		end)

		map(buf, { "i", "n" }, "<S-Tab>", function()
			if vim.api.nvim_get_current_win() == state.search_win then
				vim.api.nvim_set_current_win(state.results_win)
				vim.cmd("stopinsert")
			elseif vim.api.nvim_get_current_win() == state.replace_win then
				vim.api.nvim_set_current_win(state.search_win)
				vim.cmd("startinsert!")
			end
		end)
	end

	-- Search buffer keymaps
	map(state.search_buf, { "i", "n" }, "<CR>", function()
		vim.api.nvim_set_current_win(state.replace_win)
		vim.cmd("startinsert!")
	end)
	
	map(state.search_buf, { "i", "n" }, "<Down>", function()
		vim.api.nvim_set_current_win(state.replace_win)
		vim.cmd("startinsert!")
	end)

	-- Replace buffer keymaps
	map(state.replace_buf, { "i", "n" }, "<CR>", function()
		vim.api.nvim_set_current_win(state.results_win)
		vim.cmd("stopinsert")
	end)
	
	map(state.replace_buf, { "i", "n" }, "<Down>", function()
		vim.api.nvim_set_current_win(state.results_win)
		vim.cmd("stopinsert")
	end)

	map(state.replace_buf, { "i", "n" }, "<Up>", function()
		vim.api.nvim_set_current_win(state.search_win)
		vim.cmd("startinsert!")
	end)

	-- Results buffer: Tab/Shift-Tab to navigate to input fields
	map(state.results_buf, "n", "<Tab>", function()
		vim.api.nvim_set_current_win(state.search_win)
		vim.cmd("startinsert!")
	end)
	
	map(state.results_buf, "n", "<S-Tab>", function()
		vim.api.nvim_set_current_win(state.replace_win)
		vim.cmd("startinsert!")
	end)

	-- Results buffer: Update preview on cursor move
	vim.api.nvim_create_autocmd("CursorMoved", {
		buffer = state.results_buf,
		callback = callbacks.update_cursor_preview,
	})

	-- Replace actions (works in both normal and visual mode)
	for _, key in ipairs(kb.replace_selected.keys) do
		map(state.results_buf, "n", key, callbacks.replace_selected)
		map(state.results_buf, "v", key, callbacks.replace_selected)
	end
	
	for _, key in ipairs(kb.open_in_file.keys) do
		map(state.results_buf, "n", key, callbacks.open_in_file)
	end
	
	for _, key in ipairs(kb.replace_all.keys) do
		map(state.results_buf, "n", key, callbacks.replace_all)
	end

	-- Jump to edit mode
	for _, key in ipairs(kb.jump_search.keys) do
		map(state.results_buf, "n", key, function()
			vim.api.nvim_set_current_win(state.search_win)
			vim.cmd("startinsert!")
		end)
	end

	for _, key in ipairs(kb.jump_replace.keys) do
		map(state.results_buf, "n", key, function()
			vim.api.nvim_set_current_win(state.replace_win)
			vim.cmd("startinsert!")
		end)
	end

	-- Auto-search on text change in search buffer
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		buffer = state.search_buf,
		callback = callbacks.do_search,
	})

	-- Auto-update preview on replace text change
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		buffer = state.replace_buf,
		callback = callbacks.update_preview_text,
	})
end

return M
