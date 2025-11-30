-- nvim-search-and-replace UI module
-- Provides a custom split-pane interface for project-wide find and replace

local M = {}

-- UI state
local state = {
  search_text = "",
  replace_text = "",
  results = {},
  selected_idx = 1,
  selected_items = {},  -- Set of selected indices for multi-selection
  help_shown = true,
  
  -- Window and buffer handles
  search_buf = nil,
  replace_buf = nil,
  results_buf = nil,
  preview_buf = nil,
  
  search_win = nil,
  replace_win = nil,
  results_win = nil,
  preview_win = nil,
}

local replacer = require("nvim-search-and-replace.replace")

-- Run ripgrep to find matches
local function run_ripgrep(search, opts)
  if not search or search == "" then
    return {}
  end
  
  opts = opts or {}
  local cmd = { opts.rg_binary or "rg", "--color=never", "--no-heading", "--line-number", "--column" }
  
  if opts.literal ~= false then
    table.insert(cmd, "--fixed-strings")
  end
  
  if opts.smart_case ~= false then
    table.insert(cmd, "--smart-case")
  end
  
  table.insert(cmd, search)
  table.insert(cmd, opts.cwd or vim.loop.cwd())
  
  local results = {}
  local job_id = vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            -- Parse: filename:line:col:content
            local filename, lnum, col, text = line:match("^([^:]+):(%d+):(%d+):(.*)$")
            if filename then
              table.insert(results, {
                filename = filename,
                lnum = tonumber(lnum),
                col = tonumber(col),
                text = text,
              })
            end
          end
        end
      end
    end,
  })
  
  vim.fn.jobwait({job_id}, 5000)
  return results
end

local function update_preview()
  if not state.preview_buf or not vim.api.nvim_buf_is_valid(state.preview_buf) then
    return
  end
  
  -- Make buffer modifiable temporarily
  vim.api.nvim_buf_set_option(state.preview_buf, "modifiable", true)
  
  local result = state.results[state.selected_idx]
  if not result then
    vim.api.nvim_buf_set_lines(state.preview_buf, 0, -1, false, {"No selection"})
    vim.api.nvim_buf_set_option(state.preview_buf, "modifiable", false)
    return
  end
  
  local ok, file_lines = pcall(vim.fn.readfile, result.filename)
  if not ok then
    vim.api.nvim_buf_set_lines(state.preview_buf, 0, -1, false, {"Cannot read file"})
    vim.api.nvim_buf_set_option(state.preview_buf, "modifiable", false)
    return
  end
  
  local lnum = result.lnum
  local context_before = 5
  local context_after = 5
  local start_line = math.max(1, lnum - context_before)
  local end_line = math.min(#file_lines, lnum + context_after)
  
  local preview_lines = {}
  local before_line_idx = nil
  local after_line_idx = nil
  
  -- Add filename header
  local cwd = vim.loop.cwd()
  local rel_path = result.filename
  if rel_path:sub(1, #cwd) == cwd then
    rel_path = rel_path:sub(#cwd + 2)
  end
  table.insert(preview_lines, "╔═══ " .. rel_path .. " ═══")
  table.insert(preview_lines, "")
  
  -- Show context with before/after
  for i = start_line, end_line do
    local line = file_lines[i] or ""
    local prefix = string.format("%4d │ ", i)
    
    if i == lnum and state.replace_text ~= "" then
      -- Show the change
      local new_line = replacer.compute_line(line, result.col, state.search_text, state.replace_text, {literal = true})
      
      table.insert(preview_lines, "")
      table.insert(preview_lines, "     │ BEFORE:")
      before_line_idx = #preview_lines + 1
      table.insert(preview_lines, prefix .. line)
      table.insert(preview_lines, "     │")
      table.insert(preview_lines, "     │ AFTER:")
      after_line_idx = #preview_lines + 1
      table.insert(preview_lines, prefix .. (new_line or line))
      table.insert(preview_lines, "")
    else
      table.insert(preview_lines, prefix .. line)
    end
  end
  
  vim.api.nvim_buf_set_lines(state.preview_buf, 0, -1, false, preview_lines)
  
  -- Detect filetype and enable syntax highlighting
  local filetype = vim.filetype.match({ filename = result.filename })
  if filetype then
    vim.api.nvim_buf_set_option(state.preview_buf, "filetype", filetype)
  end
  
  -- Set back to non-modifiable
  vim.api.nvim_buf_set_option(state.preview_buf, "modifiable", false)
  
  -- Highlight the changed line
  local ns = vim.api.nvim_create_namespace("nvim_search_and_replace_preview")
  vim.api.nvim_buf_clear_namespace(state.preview_buf, ns, 0, -1)
  
  -- Highlight header
  vim.api.nvim_buf_add_highlight(state.preview_buf, ns, "Title", 0, 0, -1)
  
  -- Highlight line numbers for all lines
  for i, line in ipairs(preview_lines) do
    if line:match("^%s*%d+%s*│") then
      local num_end = line:find("│")
      if num_end then
        vim.api.nvim_buf_add_highlight(state.preview_buf, ns, "LineNr", i - 1, 0, num_end)
      end
    end
  end
  
  -- Highlight the actual BEFORE and AFTER content lines (not the labels)
  if before_line_idx then
    vim.api.nvim_buf_add_highlight(state.preview_buf, ns, "DiffDelete", before_line_idx - 1, 0, -1)
  end
  if after_line_idx then
    vim.api.nvim_buf_add_highlight(state.preview_buf, ns, "DiffAdd", after_line_idx - 1, 0, -1)
  end
  
  -- Highlight the search term in the preview
  if state.search_text ~= "" then
    for i, line in ipairs(preview_lines) do
      local match_start = line:find(vim.pesc(state.search_text))
      if match_start then
        vim.api.nvim_buf_add_highlight(state.preview_buf, ns, "Search", i - 1, match_start - 1, match_start - 1 + #state.search_text)
      end
    end
  end
end

local function update_results_list()
  if not state.results_buf or not vim.api.nvim_buf_is_valid(state.results_buf) then
    return
  end
  
  -- If help is still shown and no search has been done, keep the help
  if state.help_shown and state.search_text == "" then
    return
  end
  
  -- Make buffer modifiable temporarily
  vim.api.nvim_buf_set_option(state.results_buf, "modifiable", true)
  
  local cwd = vim.loop.cwd()
  local lines = {}
  for i, result in ipairs(state.results) do
    local is_selected = state.selected_items[i] ~= nil
    local marker = (i == state.selected_idx) and "▶ " or "  "
    if is_selected then
      marker = (i == state.selected_idx) and "▶✓" or " ✓"
    end
    -- Convert to relative path
    local rel_path = result.filename
    if rel_path:sub(1, #cwd) == cwd then
      rel_path = rel_path:sub(#cwd + 2)  -- +2 to skip the trailing slash
    end
    
    local display = string.format("%s%s:%d:%d: %s", 
      marker, 
      rel_path, 
      result.lnum, 
      result.col, 
      result.text:sub(1, 60)
    )
    table.insert(lines, display)
  end
  
  if #lines == 0 then
    lines = {"No results"}
  end
  
  vim.api.nvim_buf_set_lines(state.results_buf, 0, -1, false, lines)
  
  -- Set back to non-modifiable
  vim.api.nvim_buf_set_option(state.results_buf, "modifiable", false)
  
  -- Highlight selected line and marked items
  local ns = vim.api.nvim_create_namespace("nvim_search_and_replace_selection")
  vim.api.nvim_buf_clear_namespace(state.results_buf, ns, 0, -1)
  if state.selected_idx > 0 and state.selected_idx <= #state.results then
    vim.api.nvim_buf_add_highlight(state.results_buf, ns, "Visual", state.selected_idx - 1, 0, -1)
  end
  
  -- Highlight marked items with a different color
  for idx, _ in pairs(state.selected_items) do
    if idx ~= state.selected_idx then
      vim.api.nvim_buf_add_highlight(state.results_buf, ns, "CursorLine", idx - 1, 0, -1)
    end
  end
  
  -- Add syntax highlighting for results
  for i, result in ipairs(state.results) do
    local line_idx = i - 1
    -- Highlight marker
    vim.api.nvim_buf_add_highlight(state.results_buf, ns, "Special", line_idx, 0, 2)
    
    -- Find and highlight filename, line number, column
    local line = lines[i]
    if line then
      -- Highlight filename (after marker, before first colon)
      local filename_end = line:find(":", 3)
      if filename_end then
        vim.api.nvim_buf_add_highlight(state.results_buf, ns, "Directory", line_idx, 2, filename_end - 1)
        
        -- Highlight line:col numbers
        local second_colon = line:find(":", filename_end + 1)
        if second_colon then
          local third_colon = line:find(":", second_colon + 1)
          if third_colon then
            vim.api.nvim_buf_add_highlight(state.results_buf, ns, "LineNr", line_idx, filename_end, third_colon)
            
            -- Highlight the matched text
            if state.search_text ~= "" then
              local match_start = line:find(vim.pesc(state.search_text), third_colon)
              if match_start then
                vim.api.nvim_buf_add_highlight(state.results_buf, ns, "Search", line_idx, match_start - 1, match_start - 1 + #state.search_text)
              end
            end
          end
        end
      end
    end
  end
end

local function do_search()
  state.search_text = vim.api.nvim_buf_get_lines(state.search_buf, 0, -1, false)[1] or ""
  state.results = run_ripgrep(state.search_text, {literal = true})
  state.selected_idx = 1
  state.selected_items = {}  -- Clear selection on new search
  update_results_list()
  update_preview()
  
  -- Clear help text once user starts searching
  state.help_shown = false
end

local function create_ui()
  -- Create buffers
  state.search_buf = vim.api.nvim_create_buf(false, true)
  state.replace_buf = vim.api.nvim_create_buf(false, true)
  state.results_buf = vim.api.nvim_create_buf(false, true)
  state.preview_buf = vim.api.nvim_create_buf(false, true)
  
  vim.api.nvim_buf_set_lines(state.search_buf, 0, -1, false, {state.search_text})
  vim.api.nvim_buf_set_lines(state.replace_buf, 0, -1, false, {state.replace_text})
  
  -- Set buffer options
  for _, buf in ipairs({state.search_buf, state.replace_buf}) do
    vim.api.nvim_buf_set_option(buf, "buftype", "")
    vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
    vim.api.nvim_buf_set_option(buf, "modifiable", true)
  end
  
  vim.api.nvim_buf_set_option(state.results_buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(state.results_buf, "modifiable", false)
  vim.api.nvim_buf_set_option(state.preview_buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(state.preview_buf, "modifiable", false)
  
  -- Layout - smaller and centered (80% of screen)
  local width = vim.o.columns
  local height = vim.o.lines - 2
  
  local ui_width = math.floor(width * 0.8)
  local ui_height = math.floor(height * 0.8)
  local start_col = math.floor((width - ui_width) / 2)
  local start_row = math.floor((height - ui_height) / 2)
  
  local left_width = math.floor(ui_width * 0.5)
  local right_width = ui_width - left_width
  
  -- Search input (top left)
  state.search_win = vim.api.nvim_open_win(state.search_buf, true, {
    relative = "editor",
    width = left_width - 2,
    height = 1,
    row = start_row,
    col = start_col,
    style = "minimal",
    border = "rounded",
    title = " Search ",
    title_pos = "center",
  })
  
  -- Replace input (below search)
  state.replace_win = vim.api.nvim_open_win(state.replace_buf, false, {
    relative = "editor",
    width = left_width - 2,
    height = 1,
    row = start_row + 3,
    col = start_col,
    style = "minimal",
    border = "rounded",
    title = " Replace ",
    title_pos = "center",
  })
  
  -- Results list (below replace)
  state.results_win = vim.api.nvim_open_win(state.results_buf, false, {
    relative = "editor",
    width = left_width - 2,
    height = ui_height - 8,
    row = start_row + 6,
    col = start_col,
    style = "minimal",
    border = "rounded",
    title = " Results (j/k: move, Tab: select, S-Tab: unselect, <CR>: replace, <C-a>: all) ",
    title_pos = "center",
  })
  
  -- Preview (right side)
  state.preview_win = vim.api.nvim_open_win(state.preview_buf, false, {
    relative = "editor",
    width = right_width - 2,
    height = ui_height - 2,
    row = start_row,
    col = start_col + left_width,
    style = "minimal",
    border = "rounded",
    title = " Preview ",
    title_pos = "center",
  })
  
  -- Set window options
  vim.api.nvim_win_set_option(state.search_win, "wrap", false)
  vim.api.nvim_win_set_option(state.replace_win, "wrap", false)
  vim.api.nvim_win_set_option(state.results_win, "cursorline", true)
  vim.api.nvim_win_set_option(state.results_win, "wrap", false)
  vim.api.nvim_win_set_option(state.preview_win, "wrap", true)
end

local function setup_keymaps()
  local function map(buf, mode, key, fn)
    vim.keymap.set(mode, key, fn, { buffer = buf, noremap = true, silent = true })
  end
  
  -- Common keymaps for ALL buffers
  for _, buf in ipairs({state.search_buf, state.replace_buf, state.results_buf, state.preview_buf}) do
    -- Close on q, Esc (normal mode), or Ctrl+C
    map(buf, "n", "q", M.close)
    map(buf, "n", "<Esc>", M.close)
    map(buf, {"n", "i"}, "<C-c>", M.close)
    
    -- Undo with 'u' key
    map(buf, "n", "u", function()
      replacer.undo_last()
      do_search()
    end)
    
    -- Also keep Ctrl+z for undo
    map(buf, {"n", "i"}, "<C-z>", function()
      replacer.undo_last()
      do_search()
    end)
    
    -- Ctrl+j/k for navigation between windows
    map(buf, {"n", "i"}, "<C-j>", function()
      if vim.api.nvim_get_current_win() == state.search_win then
        vim.api.nvim_set_current_win(state.replace_win)
        vim.cmd("startinsert!")
      elseif vim.api.nvim_get_current_win() == state.replace_win then
        vim.api.nvim_set_current_win(state.results_win)
        vim.cmd("stopinsert")
      elseif vim.api.nvim_get_current_win() == state.results_win then
        vim.api.nvim_set_current_win(state.search_win)
        vim.cmd("startinsert!")
      end
    end)
    
    map(buf, {"n", "i"}, "<C-k>", function()
      if vim.api.nvim_get_current_win() == state.search_win then
        vim.api.nvim_set_current_win(state.results_win)
        vim.cmd("stopinsert")
      elseif vim.api.nvim_get_current_win() == state.replace_win then
        vim.api.nvim_set_current_win(state.search_win)
        vim.cmd("startinsert!")
      elseif vim.api.nvim_get_current_win() == state.results_win then
        vim.api.nvim_set_current_win(state.replace_win)
        vim.cmd("startinsert!")
      end
    end)
  end
  
  -- Tab/Shift-Tab for multi-selection in results buffer only
  for _, buf in ipairs({state.search_buf, state.replace_buf}) do
    map(buf, {"i", "n"}, "<Tab>", function()
      if vim.api.nvim_get_current_win() == state.search_win then
        vim.api.nvim_set_current_win(state.replace_win)
        vim.cmd("startinsert!")
      elseif vim.api.nvim_get_current_win() == state.replace_win then
        vim.api.nvim_set_current_win(state.results_win)
        vim.cmd("stopinsert")
      end
    end)
    
    map(buf, {"i", "n"}, "<S-Tab>", function()
      if vim.api.nvim_get_current_win() == state.search_win then
        vim.api.nvim_set_current_win(state.results_win)
        vim.cmd("stopinsert")
      elseif vim.api.nvim_get_current_win() == state.replace_win then
        vim.api.nvim_set_current_win(state.search_win)
        vim.cmd("startinsert!")
      end
    end)
  end
  
  -- Results buffer: Tab to select, Shift-Tab to unselect
  map(state.results_buf, "n", "<Tab>", function()
    if state.selected_idx > 0 and state.selected_idx <= #state.results then
      state.selected_items[state.selected_idx] = true
      update_results_list()
      -- Move to next item
      if state.selected_idx < #state.results then
        state.selected_idx = state.selected_idx + 1
        update_results_list()
        update_preview()
        vim.api.nvim_win_set_cursor(state.results_win, {state.selected_idx, 0})
      end
    end
  end)
  
  map(state.results_buf, "n", "<S-Tab>", function()
    if state.selected_idx > 0 and state.selected_idx <= #state.results then
      state.selected_items[state.selected_idx] = nil
      update_results_list()
      -- Move to previous item
      if state.selected_idx > 1 then
        state.selected_idx = state.selected_idx - 1
        update_results_list()
        update_preview()
        vim.api.nvim_win_set_cursor(state.results_win, {state.selected_idx, 0})
      end
    end
  end)
  
  -- Search buffer keymaps
  map(state.search_buf, {"i", "n"}, "<Down>", function()
    vim.api.nvim_set_current_win(state.replace_win)
    vim.cmd("startinsert!")
  end)
  
  -- Replace buffer keymaps
  map(state.replace_buf, {"i", "n"}, "<Down>", function()
    vim.api.nvim_set_current_win(state.results_win)
    vim.cmd("stopinsert")
  end)
  
  map(state.replace_buf, {"i", "n"}, "<Up>", function()
    vim.api.nvim_set_current_win(state.search_win)
    vim.cmd("startinsert!")
  end)
  
  -- Results buffer keymaps
  map(state.results_buf, "n", "j", function()
    if state.selected_idx < #state.results then
      state.selected_idx = state.selected_idx + 1
      update_results_list()
      update_preview()
      -- Scroll to keep selection visible
      vim.api.nvim_win_set_cursor(state.results_win, {state.selected_idx, 0})
    end
  end)
  
  map(state.results_buf, "n", "<Down>", function()
    if state.selected_idx < #state.results then
      state.selected_idx = state.selected_idx + 1
      update_results_list()
      update_preview()
      -- Scroll to keep selection visible
      vim.api.nvim_win_set_cursor(state.results_win, {state.selected_idx, 0})
    end
  end)
  
  map(state.results_buf, "n", "k", function()
    if state.selected_idx > 1 then
      state.selected_idx = state.selected_idx - 1
      update_results_list()
      update_preview()
      -- Scroll to keep selection visible
      vim.api.nvim_win_set_cursor(state.results_win, {state.selected_idx, 0})
    end
  end)
  
  map(state.results_buf, "n", "<Up>", function()
    if state.selected_idx > 1 then
      state.selected_idx = state.selected_idx - 1
      update_results_list()
      update_preview()
      -- Scroll to keep selection visible
      vim.api.nvim_win_set_cursor(state.results_win, {state.selected_idx, 0})
    end
  end)
  
  map(state.results_buf, "n", "<CR>", function()
    -- If items are marked, replace in all marked items
    local items_to_replace = {}
    if next(state.selected_items) then
      for idx, _ in pairs(state.selected_items) do
        table.insert(items_to_replace, state.results[idx])
      end
    else
      -- Otherwise, just replace the current item
      if state.results[state.selected_idx] then
        items_to_replace = {state.results[state.selected_idx]}
      end
    end
    
    if #items_to_replace > 0 then
      state.replace_text = vim.api.nvim_buf_get_lines(state.replace_buf, 0, -1, false)[1] or ""
      local summary = replacer.apply(items_to_replace, state.search_text, state.replace_text, {literal = true})
      replacer.notify_summary(summary)
      -- Refresh results
      do_search()
    end
  end)
  
  map(state.results_buf, "n", "<C-a>", function()
    state.replace_text = vim.api.nvim_buf_get_lines(state.replace_buf, 0, -1, false)[1] or ""
    local summary = replacer.apply(state.results, state.search_text, state.replace_text, {literal = true})
    replacer.notify_summary(summary)
    M.close()
  end)
  
  map(state.results_buf, "n", "i", function()
    vim.api.nvim_set_current_win(state.search_win)
    vim.cmd("startinsert!")
  end)
  
  map(state.results_buf, "n", "a", function()
    vim.api.nvim_set_current_win(state.search_win)
    vim.cmd("startinsert!")
  end)
  
  map(state.results_buf, "n", "I", function()
    vim.api.nvim_set_current_win(state.replace_win)
    vim.cmd("startinsert!")
  end)
  
  -- Auto-search on text change in search buffer
  vim.api.nvim_create_autocmd({"TextChanged", "TextChangedI"}, {
    buffer = state.search_buf,
    callback = function()
      vim.defer_fn(do_search, 300)
    end
  })
  
  -- Auto-update preview on replace text change
  vim.api.nvim_create_autocmd({"TextChanged", "TextChangedI"}, {
    buffer = state.replace_buf,
    callback = function()
      state.replace_text = vim.api.nvim_buf_get_lines(state.replace_buf, 0, -1, false)[1] or ""
      update_preview()
      -- Clear help on first replace text change
      if state.help_shown then
        state.help_shown = false
        update_results_list()
      end
    end
  })
  
  -- Show help text in results buffer initially and keep it until user types
  vim.schedule(function()
    if state.results_buf and vim.api.nvim_buf_is_valid(state.results_buf) then
      vim.api.nvim_buf_set_option(state.results_buf, "modifiable", true)
      vim.api.nvim_buf_set_lines(state.results_buf, 0, -1, false, {
        "Type in Search field to find matches",
        "",
        "Navigation:",
        "  <C-j> / <C-k>           - Move between input fields and results",
        "  j/k or ↑/↓              - Navigate results list",
        "",
        "Selection:",
        "  <Tab>                   - Mark/select current item",
        "  <S-Tab>                 - Unmark/unselect current item",
        "",
        "Actions:",
        "  <CR>                    - Replace current (or all marked items)",
        "  <C-a>                   - Replace ALL matches",
        "  u                       - Undo last replacement",
        "  <Esc> / q               - Close",
      })
      vim.api.nvim_buf_set_option(state.results_buf, "modifiable", false)
    end
  end)
end

function M.open(opts)
  opts = opts or {}
  state.search_text = opts.search or ""
  state.replace_text = opts.replace or ""
  state.help_shown = true
  state.selected_items = {}  -- Reset selection
  
  create_ui()
  setup_keymaps()
  
  -- Start in insert mode in search field
  vim.api.nvim_set_current_win(state.search_win)
  vim.cmd("startinsert")
end

function M.close()
  for _, win in ipairs({state.search_win, state.replace_win, state.results_win, state.preview_win}) do
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  
  state.search_win = nil
  state.replace_win = nil
  state.results_win = nil
  state.preview_win = nil
end

return M
