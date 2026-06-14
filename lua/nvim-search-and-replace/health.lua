-- Health check module for nvim-search-and-replace
local M = {}

function M.check()
	-- Neovim 0.10 renamed the reporters from `report_*` to short names.
	-- Resolve both so checkhealth works on the advertised 0.8+ range.
	local h = vim.health or {}
	local start = h.start or h.report_start
	local ok_fn = h.ok or h.report_ok
	local info = h.info or h.report_info
	local warn = h.warn or h.report_warn
	local error_fn = h.error or h.report_error

	start("nvim-search-and-replace")

	-- Check Neovim version
	if vim.fn.has("nvim-0.8") == 1 then
		ok_fn("Neovim version >= 0.8")
	else
		error_fn("Neovim 0.8+ is required")
	end

	-- Check ripgrep installation
	local rg_path = vim.fn.exepath("rg")
	if rg_path and rg_path ~= "" then
		ok_fn("ripgrep found: " .. rg_path)

		-- Check ripgrep version
		local handle = io.popen("rg --version 2>&1")
		if handle then
			local result = handle:read("*l")
			handle:close()
			if result then
				info("ripgrep version: " .. result)
			end
		end
	else
		error_fn("ripgrep (rg) not found in PATH", {
			"Install ripgrep: https://github.com/BurntSushi/ripgrep#installation",
			"Ensure 'rg' is available in your PATH",
		})
	end

	-- Check configuration
	local ok, plugin = pcall(require, "nvim-search-and-replace")
	if ok then
		local config = plugin.get_config()
		ok_fn("Plugin loaded successfully (version " .. tostring(plugin.version) .. ")")
		info("Config: smart_case=" .. tostring(config.smart_case))
		info("Config: max_results=" .. tostring(config.max_results))
		info("Config: max_file_size=" .. tostring(config.max_file_size))
		info("Config: debounce_ms=" .. tostring(config.debounce_ms))
		info("Config: multiline=" .. tostring(config.multiline))
		info("Config: sort=" .. tostring(config.sort))
	else
		warn("Plugin not loaded (this is normal if setup() hasn't been called)")
	end
end

return M
