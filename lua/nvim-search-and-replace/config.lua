-- Config module - centralized keybinding configuration
local M = {}

-- Keybinding definitions
-- Format: key = { keys = "...", description = "..." }
M.keybindings = {
	-- Help
	help = { keys = { "?", "<F1>" }, description = "Toggle this help window" },
	
	-- Navigation
	next_field = { keys = { "<CR>", "<Tab>" }, description = "Move to next field (Search → Replace → Results)" },
	prev_field = { keys = { "<S-Tab>" }, description = "Move to previous field" },
	jump_search = { keys = { "i", "a" }, description = "Jump to search field" },
	jump_replace = { keys = { "I" }, description = "Jump to replace field" },
	
	-- Selection (in results)
	visual_select = { keys = { "v", "V" }, description = "Visual mode to select multiple results" },
	
	-- Actions
	replace_selected = { keys = { "<CR>" }, description = "Replace current (or all marked items)", context = "in results" },
	replace_all = { keys = { "<C-a>" }, description = "Replace ALL matches" },
	toggle_regex = { keys = { "<C-t>" }, description = "Toggle regex/literal mode" },
	stop_search = { keys = { "<C-x>" }, description = "Stop/abort current search" },
	undo = { keys = { "u", "<C-z>" }, description = "Undo last replacement" },
	redo = { keys = { "<C-r>", "<C-S-z>" }, description = "Redo last replacement" },
	
	-- Other
	close = { keys = { "<Esc>", "q" }, description = "Close" },
}

-- Format keybindings for display
function M.format_keys(key_table)
	if type(key_table) == "string" then
		return key_table
	elseif type(key_table) == "table" then
		return table.concat(key_table, " / ")
	end
	return ""
end

-- Get help text lines with actual keybindings
function M.get_help_lines()
	local kb = M.keybindings
	
	return {
		"",
		"  SEARCH AND REPLACE - HELP",
		"",
		"  Navigation:",
		"    " .. M.format_keys(kb.next_field.keys) .. string.rep(" ", 28 - #M.format_keys(kb.next_field.keys)) .. "- " .. kb.next_field.description,
		"    " .. M.format_keys(kb.prev_field.keys) .. string.rep(" ", 28 - #M.format_keys(kb.prev_field.keys)) .. "- " .. kb.prev_field.description,
		"    j/k or arrow keys" .. string.rep(" ", 28 - 17) .. "- Navigate results list",
		"",
		"  Selection (in results):",
		"    " .. M.format_keys(kb.visual_select.keys) .. string.rep(" ", 28 - #M.format_keys(kb.visual_select.keys)) .. "- " .. kb.visual_select.description,
		"",
		"  Actions:",
		"    " .. M.format_keys(kb.replace_selected.keys) .. " (in results)" .. string.rep(" ", 28 - #(M.format_keys(kb.replace_selected.keys) .. " (in results)")) .. "- " .. kb.replace_selected.description,
		"    " .. M.format_keys(kb.replace_all.keys) .. string.rep(" ", 28 - #M.format_keys(kb.replace_all.keys)) .. "- " .. kb.replace_all.description,
		"    " .. M.format_keys(kb.toggle_regex.keys) .. string.rep(" ", 28 - #M.format_keys(kb.toggle_regex.keys)) .. "- " .. kb.toggle_regex.description,
		"    " .. M.format_keys(kb.stop_search.keys) .. string.rep(" ", 28 - #M.format_keys(kb.stop_search.keys)) .. "- " .. kb.stop_search.description,
		"    " .. M.format_keys(kb.undo.keys) .. string.rep(" ", 28 - #M.format_keys(kb.undo.keys)) .. "- " .. kb.undo.description,
		"    " .. M.format_keys(kb.redo.keys) .. string.rep(" ", 28 - #M.format_keys(kb.redo.keys)) .. "- " .. kb.redo.description,
		"",
		"  Other:",
		"    " .. M.format_keys(kb.help.keys) .. string.rep(" ", 28 - #M.format_keys(kb.help.keys)) .. "- " .. kb.help.description,
		"    " .. M.format_keys(kb.close.keys) .. string.rep(" ", 28 - #M.format_keys(kb.close.keys)) .. "- " .. kb.close.description,
		"",
	}
end

return M
