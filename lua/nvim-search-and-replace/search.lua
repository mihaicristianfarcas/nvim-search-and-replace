-- Search module - handles asynchronous ripgrep search operations with JSON output
local M = {}

local active_job = nil
local active_token = nil
local uv = vim.loop

-- Token-based cancellation: each search gets a unique token
-- Only callbacks from the latest token are honored
-- Prevents stale search results from updating UI after new search starts
local function is_current(token)
	return token == active_token
end

-- Stops the currently running ripgrep job and invalidates its callbacks
function M.stop_search()
	if active_job and active_job > 0 then
		pcall(vim.fn.jobstop, active_job)
	end
	active_job = nil
	active_token = nil
end

-- Runs async streaming ripgrep search with JSON output for precise match information
-- Provides batch callbacks for progressive UI updates to keep interface responsive
--
-- @param search: regex search pattern
-- @param opts: table with options:
--   - smart_case: boolean (default true) - case-insensitive if pattern is all lowercase
--   - batch_size: number (default 25) - results per batch callback
--   - max_results: number (default 10000) - truncate after this many results
--   - max_file_size: string (default "1M") - skip files larger than this
--   - cwd: string (optional) - directory to search in
-- @param on_results: function(results, count, truncated) - called for each batch
-- @param on_complete: function(results, count, truncated) - called when search completes
-- @return job_id: number - the jobstart ID
function M.run_ripgrep_async(search, opts, on_results, on_complete)
	if not search or search == "" then
		if on_complete then
			vim.schedule(function()
				on_complete({}, 0, false)
			end)
		end
		return nil
	end

	M.stop_search()

	opts = opts or {}
	local batch_size = opts.batch_size or 25
	local max_results = opts.max_results or 10000
	local max_file_size = opts.max_file_size or "1M"

	-- Build ripgrep command with JSON output for precise match information
	-- Always uses regex mode (no --fixed-strings flag)
	local cmd = {
		"rg",
		"--json", -- JSON output with match details
		"--max-filesize=" .. max_file_size,
	}

	-- Optional stable ordering. --sort forces ripgrep single-threaded, so allow
	-- disabling it (false/"none") to regain parallelism on large trees at the
	-- cost of deterministic result order. Defaults to "path".
	local sort = opts.sort
	if sort == nil then
		sort = "path"
	end
	if sort and sort ~= "none" and sort ~= false then
		cmd[#cmd + 1] = "--sort=" .. sort
	end

	if opts.smart_case ~= false then
		cmd[#cmd + 1] = "--smart-case" -- Case-insensitive if pattern is lowercase
	end

	if opts.multiline then
		cmd[#cmd + 1] = "--multiline" -- Enable multiline matching
	end

	-- Add -- to separate flags from search pattern (important for patterns starting with -)
	cmd[#cmd + 1] = "--"
	cmd[#cmd + 1] = search
	cmd[#cmd + 1] = opts.cwd or uv.cwd()

	local results = {}
	local batch = {}
	local result_count = 0
	local truncated = false
	local regex_error = nil
	local token = uv.hrtime() -- Unique token for this search

	-- Emits accumulated batch to UI callback
	local function emit_batch()
		if #batch > 0 and on_results then
			local emit_batch = batch
			local count = result_count
			batch = {}
			vim.schedule(function()
				if is_current(token) then
					on_results(emit_batch, count, truncated)
				end
			end)
		end
	end

	local job_id = vim.fn.jobstart(cmd, {
		stdout_buffered = false,
		stderr_buffered = true,
		on_stderr = function(_, data)
			if not is_current(token) or not data then
				return
			end
			-- Capture regex errors from ripgrep stderr
			for _, line in ipairs(data) do
				if line and line ~= "" then
					-- Ripgrep outputs "error: " prefix for regex errors
					if line:match("^error:") or line:match("regex parse error") then
						regex_error = line:gsub("^error:%s*", "")
					end
				end
			end
		end,
		on_stdout = function(_, data)
			if not is_current(token) or not data then
				return
			end

			-- Early exit if already hit max results
			if truncated then
				return
			end

			for i = 1, #data do
				local line = data[i]
				if line ~= "" then
					-- Check limit before expensive parsing
					if result_count >= max_results then
						truncated = true
						emit_batch() -- Flush remaining results
						pcall(vim.fn.jobstop, job_id)
						return -- Exit immediately to avoid further processing
					end

					-- Parse JSON output from ripgrep
					local ok, json = pcall(vim.json.decode, line)
					if ok and json and json.type == "match" then
						local data = json.data
						-- Ensure text fields exist (skip binary files or malformed output)
						if data.path and data.path.text and data.lines and data.lines.text then
							local filename = data.path.text
							local lnum = data.line_number
							-- For display, use only the first physical line of the match.
							-- In multiline mode data.lines.text can span several lines with
							-- embedded newlines, which are illegal in a buffer line; the full
							-- (newline-containing) matched text is preserved in match_text below.
							local raw = data.lines.text
							local nl = raw:find("\n", 1, true)
							local line_text = nl and raw:sub(1, nl - 1) or raw

							-- Truncate text to prevent memory issues with very long lines
							if #line_text > 500 then
								line_text = line_text:sub(1, 500) .. "..."
							end

							-- Process each submatch (there can be multiple matches per line)
							-- Example: "foo 123 bar 456" with pattern "\d+" yields 2 submatches
							for _, submatch in ipairs(data.submatches or {}) do
								-- Ensure match object and text exist (skip binary/malformed matches)
								if submatch.match and submatch.match.text then
									result_count = result_count + 1

									-- Convert byte offsets: ripgrep uses 0-indexed, we use 1-indexed
									local col = submatch.start + 1
									local match_text = submatch.match.text  -- The actual matched string
									local match_len = submatch["end"] - submatch.start

									local result = {
										filename = filename,
										lnum = lnum,
										col = col,
										text = line_text,
										match_text = match_text, -- Exact string that matched (used for highlighting & replacement)
										match_len = match_len, -- Length of match in bytes
									}
									results[result_count] = result
									batch[#batch + 1] = result

									-- Emit batch when full for progressive UI updates
									if #batch >= batch_size then
										emit_batch()
									end

									-- Check limit after adding result
									if result_count >= max_results then
										truncated = true
										emit_batch()
										pcall(vim.fn.jobstop, job_id)
										return
									end
								end
							end
						end
					end
				end
			end
		end,
		on_exit = function(_, exit_code)
			if not is_current(token) then
				return
			end

			emit_batch()

			if on_complete then
				vim.schedule(function()
					if is_current(token) then
						on_complete(results, exit_code, truncated, regex_error)
						active_job = nil
						active_token = nil
					end
				end)
			else
				active_job = nil
				active_token = nil
			end
		end,
	})

	if not job_id or job_id <= 0 then
		active_job = nil
		active_token = nil
		if on_complete then
			vim.schedule(function()
				on_complete({}, -1, false, nil)
			end)
		end
		return job_id
	end

	active_job = job_id
	active_token = token
	return job_id
end

return M
