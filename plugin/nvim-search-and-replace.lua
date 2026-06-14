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

-- Returns the most recent visual selection (from the '< and '> marks).
-- Multi-line selections collapse to the first line's portion, since the
-- search field is a single-line input.
local function get_visual_selection()
	local s = vim.fn.getpos("'<")
	local e = vim.fn.getpos("'>")
	local srow, scol = s[2], s[3]
	local erow, ecol = e[2], e[3]
	if srow == 0 or erow == 0 then
		return ""
	end

	local lines = vim.fn.getline(srow, erow)
	if type(lines) == "string" then
		lines = { lines }
	end
	if #lines == 0 then
		return ""
	end

	if #lines == 1 then
		-- Clamp the (inclusive) end column; linewise selections report a huge value.
		ecol = math.min(ecol, #lines[1])
		return string.sub(lines[1], scol, ecol)
	end

	-- Multi-line: use the selected portion of the first line only.
	return string.sub(lines[1], scol)
end

-- Command to open with visual selection or word under cursor
vim.api.nvim_create_user_command("SearchAndReplaceVisual", function(opts)
	local text = ""

	-- When invoked over a range (e.g. from visual mode via `:`), Vim has already
	-- left visual mode, so read the selection from the '< / '> marks instead of mode().
	if opts.range and opts.range > 0 then
		text = get_visual_selection()
	end

	if text == "" then
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
