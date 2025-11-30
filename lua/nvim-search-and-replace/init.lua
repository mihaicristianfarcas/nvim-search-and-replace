local M = {}

-- Default configuration
local defaults = {
  rg_binary = "rg",
  literal = true,      -- Use ripgrep --fixed-strings for exact matching
  smart_case = true,   -- Case insensitive unless uppercase is used
}

local config = vim.deepcopy(defaults)

function M.setup(user_opts)
  config = vim.tbl_deep_extend("force", defaults, user_opts or {})
end

function M.get_config()
  return config
end

-- Open the search and replace UI
function M.open(opts)
  return require("nvim-search-and-replace.ui").open(opts)
end

-- Undo the last replacement operation
function M.undo_last()
  return require("nvim-search-and-replace.replace").undo_last()
end

-- Redo the last replacement operation
function M.redo_last()
  return require("nvim-search-and-replace.replace").redo_last()
end

return M
