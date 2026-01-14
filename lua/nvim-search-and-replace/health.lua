-- Health check module for nvim-search-and-replace
local M = {}

function M.check()
	vim.health.start("nvim-search-and-replace")

	-- Check Neovim version
	if vim.fn.has("nvim-0.8") == 1 then
		vim.health.ok("Neovim version >= 0.8")
	else
		vim.health.error("Neovim 0.8+ is required")
	end

	-- Check ripgrep installation
	local rg_path = vim.fn.exepath("rg")
	if rg_path and rg_path ~= "" then
		vim.health.ok("ripgrep found: " .. rg_path)

		-- Check ripgrep version
		local handle = io.popen("rg --version 2>&1")
		if handle then
			local result = handle:read("*l")
			handle:close()
			if result then
				vim.health.info("ripgrep version: " .. result)
			end
		end
	else
		vim.health.error("ripgrep (rg) not found in PATH", {
			"Install ripgrep: https://github.com/BurntSushi/ripgrep#installation",
			"Ensure 'rg' is available in your PATH",
		})
	end

	-- Check configuration
	local ok, plugin = pcall(require, "nvim-search-and-replace")
	if ok then
		local config = plugin.get_config()
		vim.health.ok("Plugin loaded successfully")
		vim.health.info("Config: smart_case=" .. tostring(config.smart_case))
		vim.health.info("Config: max_results=" .. tostring(config.max_results))
		vim.health.info("Config: max_file_size=" .. tostring(config.max_file_size))
		vim.health.info("Config: debounce_ms=" .. tostring(config.debounce_ms))
	else
		vim.health.warn("Plugin not loaded (this is normal if setup() hasn't been called)")
	end
end

return M
