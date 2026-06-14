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
	replace_selected = {
		keys = { "<CR>" },
		description = "Replace current (or all marked items)",
		context = "in results",
	},
	replace_all = { keys = { "<C-a>" }, description = "Replace ALL matches" },
	open_in_file = { keys = { "o" }, description = "Open current result in file", context = "in results" },
	stop_search = { keys = { "<C-x>" }, description = "Stop/abort current search" },
	undo = { keys = { "u", "<C-z>" }, description = "Undo last replacement" },
	redo = { keys = { "<C-r>", "<C-S-z>" }, description = "Redo last replacement" },

	-- Other
	close = { keys = { "<Esc>", "q" }, description = "Close" },
}

function M.update_keybindings(user_keys)
	if not user_keys then
		return
	end
	for action, user_config in pairs(user_keys) do
		if M.keybindings[action] then
			if type(user_config) == "table" then
				-- User passed a table with keys and optionally description
				if user_config.keys then
					if type(user_config.keys) == "table" then
						M.keybindings[action].keys = vim.deepcopy(user_config.keys)
					elseif type(user_config.keys) == "string" then
						M.keybindings[action].keys = { user_config.keys }
					end
				end
				if user_config.description then
					M.keybindings[action].description = user_config.description
				end
				if user_config.context then
					M.keybindings[action].context = user_config.context
				end
			elseif type(user_config) == "string" then
				-- User passed just a string key
				M.keybindings[action].keys = { user_config }
			end
		end
	end
end

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
	local COL = 28

	-- Builds a "    <label><padding>- <description>" row.
	-- Padding is clamped to at least one space so long key lists never
	-- produce a negative string.rep count (which would raise an error).
	local function row(label, description)
		local pad = math.max(1, COL - #label)
		return "    " .. label .. string.rep(" ", pad) .. "- " .. description
	end

	-- Formatted key list for an action, with an optional suffix (e.g. " (in results)").
	local function label(action, suffix)
		local s = M.format_keys(kb[action].keys)
		if suffix then
			s = s .. suffix
		end
		return s
	end

	return {
		"",
		"  SEARCH AND REPLACE - HELP",
		"",
		"  Navigation:",
		row(label("next_field"), kb.next_field.description),
		row(label("prev_field"), kb.prev_field.description),
		row("j/k or arrow keys", "Navigate results list"),
		"",
		"  Selection (in results):",
		row(label("visual_select"), kb.visual_select.description),
		"",
		"  Actions:",
		row(label("replace_selected", " (in results)"), kb.replace_selected.description),
		row(label("replace_all"), kb.replace_all.description),
		row(label("open_in_file", " (in results)"), kb.open_in_file.description),
		row(label("stop_search"), kb.stop_search.description),
		row(label("undo"), kb.undo.description),
		row(label("redo"), kb.redo.description),
		"",
		"  Other:",
		row(label("help"), kb.help.description),
		row(label("close"), kb.close.description),
		"",
	}
end

return M
