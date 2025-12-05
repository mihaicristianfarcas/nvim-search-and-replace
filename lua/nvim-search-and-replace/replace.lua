local M = {}

local history = {}
local redo_stack = {}

local function sort_descending(entries)
  table.sort(entries, function(a, b)
    if a.filename ~= b.filename then
      return a.filename < b.filename
    end
    if a.lnum == b.lnum then
      return (a.col or 0) > (b.col or 0)
    end
    return (a.lnum or 0) > (b.lnum or 0)
  end)
end

local function validate_entry(entry)
  return entry and entry.filename and entry.lnum and entry.col
end

local function build_matcher(search, opts)
  opts = opts or {}

  if opts.literal ~= false then
    return {
      mode = "literal",
      match = function(line, col)
        local start_idx = col
        local end_idx = col + #search - 1
        local segment = string.sub(line, start_idx, end_idx)
        if segment == search then
          return start_idx, end_idx, segment
        end
        return nil, nil, segment
      end,
    }
  end

  local ok, regex = pcall(vim.regex, search)
  if not ok or not regex then
    return nil, "Invalid regex: " .. tostring(search)
  end

  return {
    mode = "regex",
    match = function(line, col)
      -- col is 1-based; vim.regex expects 0-based byte offsets.
      local sub = string.sub(line, col)
      local s, e = regex:match_str(sub)
      if not s or s ~= 0 then
        return nil, nil, nil
      end
      local start_idx = col
      local end_idx = col + e - 1
      local matched = string.sub(line, start_idx, end_idx)
      return start_idx, end_idx, matched
    end,
  }
end

local function compute_line_with_matcher(matcher, line, col, search, replace_text)
  local start_idx, end_idx, segment = matcher.match(line, col)
  if not start_idx then
    local expected = search
    local found = segment or "nothing"
    return nil, nil, segment, string.format("expected '%s' but found '%s'", expected, found)
  end

  local new_line = string.sub(line, 1, start_idx - 1) .. replace_text .. string.sub(line, end_idx + 1)
  return new_line, start_idx, end_idx, nil
end

function M.compute_line(line, col, search, replace_text, opts)
  local matcher, err = build_matcher(search, opts)
  if not matcher then
    return nil, nil, nil, err
  end
  return compute_line_with_matcher(matcher, line, col, search, replace_text)
end

function M.apply(entries, search, replace_text, opts)
  opts = opts or {}

  if not entries or #entries == 0 then
    vim.notify("No entries to replace.", vim.log.levels.WARN)
    return
  end

  if not search or search == "" then
    vim.notify("Search text is empty.", vim.log.levels.WARN)
    return
  end

  local matcher, matcher_err = build_matcher(search, opts)
  if not matcher then
    vim.notify(matcher_err or "Invalid search pattern.", vim.log.levels.WARN)
    return
  end

  local per_file = {}
  for _, entry in ipairs(entries) do
    if validate_entry(entry) then
      local file_entries = per_file[entry.filename] or {}
      table.insert(file_entries, entry)
      per_file[entry.filename] = file_entries
    end
  end

  local summary = { applied = 0, files = {}, skipped = {} }
  local op_files = {}

  for filename, file_entries in pairs(per_file) do
    sort_descending(file_entries)

    local ok, lines = pcall(vim.fn.readfile, filename)
    if not ok then
      table.insert(summary.skipped, filename .. ": failed to read file")
      goto continue
    end

    op_files[filename] = vim.deepcopy(lines)

    local file_applied = 0

    for _, entry in ipairs(file_entries) do
      local lnum = entry.lnum
      local col = entry.col
      local line = lines[lnum]

      if not line then
        table.insert(summary.skipped, string.format("%s:%d:%d missing line", filename, lnum, col))
      else
        local new_line, start_idx, end_idx, err =
          compute_line_with_matcher(matcher, line, col, search, replace_text)
        if new_line then
          lines[lnum] = new_line
          file_applied = file_applied + 1
        else
          table.insert(summary.skipped, string.format("%s:%d:%d mismatch (%s)", filename, lnum, col, err or "no match"))
        end
      end
    end

    if file_applied > 0 then
      local ok_write, err = pcall(vim.fn.writefile, lines, filename)
      if ok_write then
        summary.applied = summary.applied + file_applied
        table.insert(summary.files, filename)
      else
        table.insert(summary.skipped, string.format("%s: failed to write (%s)", filename, err))
      end
    end

    ::continue::
  end

  if summary.applied > 0 then
    table.insert(history, { files = op_files, search = search, replace = replace_text, timestamp = os.time() })
    -- Clear redo stack when new operation is performed
    redo_stack = {}
  end

  return summary
end

function M.notify_summary(summary)
  if not summary then
    return
  end

  local message = string.format("Replaced %d occurrence(s) across %d file(s).", summary.applied, #summary.files)

  if summary.skipped and #summary.skipped > 0 then
    message = message .. "\n\nSkipped (text didn't match exactly at these locations):"
    for _, skip in ipairs(summary.skipped) do
      message = message .. "\n  • " .. skip
    end
  end

  vim.notify(message, vim.log.levels.INFO)
end

function M.undo_last()
  if #history == 0 then
    vim.notify("No replace operations to undo.", vim.log.levels.INFO)
    return
  end

  local op = table.remove(history)
  if not op then
    vim.notify("No replace operations to undo.", vim.log.levels.INFO)
    return
  end

  -- Save current state before restoring for redo
  local current_state = {}
  for filename, _ in pairs(op.files or {}) do
    local ok, lines = pcall(vim.fn.readfile, filename)
    if ok then
      current_state[filename] = lines
    end
  end

  local restored, failed = 0, {}
  for filename, lines in pairs(op.files or {}) do
    local ok, err = pcall(vim.fn.writefile, lines, filename)
    if ok then
      restored = restored + 1
    else
      table.insert(failed, string.format("%s (%s)", filename, err))
    end
  end

  -- Add to redo stack with current state and operation info
  table.insert(redo_stack, {
    files = current_state,
    search = op.search,
    replace = op.replace,
    timestamp = op.timestamp
  })

  local msg = string.format("Undid replace (%d file(s) restored).", restored)
  if #history > 0 then
    msg = msg .. string.format(" %d more undo(s) available.", #history)
  end
  if #redo_stack > 0 then
    msg = msg .. string.format(" %d redo(s) available.", #redo_stack)
  end
  if #failed > 0 then
    msg = msg .. " Failed: " .. table.concat(failed, "; ")
  end
  vim.notify(msg, #failed > 0 and vim.log.levels.WARN or vim.log.levels.INFO)
end

function M.redo_last()
  if #redo_stack == 0 then
    vim.notify("No replace operations to redo.", vim.log.levels.INFO)
    return
  end

  local op = table.remove(redo_stack)
  if not op then
    vim.notify("No replace operations to redo.", vim.log.levels.INFO)
    return
  end

  -- Save current state before restoring for undo
  local current_state = {}
  for filename, _ in pairs(op.files or {}) do
    local ok, lines = pcall(vim.fn.readfile, filename)
    if ok then
      current_state[filename] = lines
    end
  end

  local restored, failed = 0, {}
  for filename, lines in pairs(op.files or {}) do
    local ok, err = pcall(vim.fn.writefile, lines, filename)
    if ok then
      restored = restored + 1
    else
      table.insert(failed, string.format("%s (%s)", filename, err))
    end
  end

  -- Add back to history
  table.insert(history, {
    files = current_state,
    search = op.search,
    replace = op.replace,
    timestamp = op.timestamp
  })

  local msg = string.format("Redid replace (%d file(s) restored).", restored)
  if #redo_stack > 0 then
    msg = msg .. string.format(" %d more redo(s) available.", #redo_stack)
  end
  if #history > 0 then
    msg = msg .. string.format(" %d undo(s) available.", #history)
  end
  if #failed > 0 then
    msg = msg .. " Failed: " .. table.concat(failed, "; ")
  end
  vim.notify(msg, #failed > 0 and vim.log.levels.WARN or vim.log.levels.INFO)
end

function M.get_history_count()
  return #history
end

function M.get_redo_count()
  return #redo_stack
end

return M
