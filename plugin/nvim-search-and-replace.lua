-- nvim-search-and-replace plugin commands

local ok, search_and_replace = pcall(require, "nvim-search-and-replace")
if not ok then
	return
end

-- Main command to open the find/replace UI
vim.api.nvim_create_user_command("SearchAndReplaceOpen", function(opts)
	search_and_replace.open(opts and opts.args ~= "" and { search = opts.args } or {})
end, {
	desc = "Open live find and replace UI",
	nargs = "?",
})

-- Command to open with visual selection or word under cursor
vim.api.nvim_create_user_command("SearchAndReplaceVisual", function()
	local mode = vim.fn.mode()
	local text = ""

	if mode == "v" or mode == "V" or mode == "\22" then -- visual mode
		-- Get visual selection
		vim.cmd('noau normal! "vy"')
		text = vim.fn.getreg("v")
	else
		-- Check if there's a search pattern in the / register (from *, /, etc.)
		local search_register = vim.fn.getreg("/")
		if search_register and search_register ~= "" then
			-- Remove Vim regex patterns like \< and \> (word boundaries) for cleaner search
			text = search_register:gsub("\\<", ""):gsub("\\>", "")
		end

		-- If no search register or empty, get word under cursor
		if text == "" then
			text = vim.fn.expand("<cword>")
		end
	end

	if text and text ~= "" then
		search_and_replace.open({ search = text })
	else
		search_and_replace.open()
	end
end, {
	desc = "Open search and replace with visual selection, search pattern, or word under cursor",
	range = true,
})

-- Command to undo the last replacement
vim.api.nvim_create_user_command("SearchAndReplaceUndo", function()
	search_and_replace.undo_last()
end, {
	desc = "Undo the last replacement operation",
})

-- Command to redo the last replacement
vim.api.nvim_create_user_command("SearchAndReplaceRedo", function()
	search_and_replace.redo_last()
end, {
	desc = "Redo the last replacement operation",
})
