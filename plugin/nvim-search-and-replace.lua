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
