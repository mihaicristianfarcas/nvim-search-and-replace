-- Search module - handles ripgrep search operations
local M = {}

local active_job = nil
local active_token = nil
local uv = vim.loop

-- token-based cancellation: each search gets a unique token
-- only callbacks from the latest token are honored
-- prevents stale search results from updating ui after new search starts
local function is_current(token)
	return token == active_token
end

-- stops the currently running ripgrep job and invalidates its callbacks
function M.stop_search()
	if active_job and active_job > 0 then
		pcall(vim.fn.jobstop, active_job)
	end
	active_job = nil
	active_token = nil
end

-- async streaming ripgrep with batch callbacks for progressive ui updates
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
	local batch_size = opts.batch_size or 50
	local max_results = opts.max_results or 10000

	-- build ripgrep command with appropriate flags
	local cmd = {
		opts.rg_binary or "rg",
		"--color=never",
		"--no-heading",
		"--line-number",
		"--column",
		"--vimgrep",
		"--sort=path",
	}

	if opts.literal == true then
		cmd[#cmd + 1] = "--fixed-strings"
	end

	if opts.smart_case ~= false then
		cmd[#cmd + 1] = "--smart-case"
	end

	cmd[#cmd + 1] = search
	cmd[#cmd + 1] = opts.cwd or uv.cwd()

	local results = {}
	local batch = {}
	local result_count = 0
	local truncated = false
	local token = uv.hrtime() -- unique token for this search

	-- pre-compiled pattern for parsing ripgrep output
	local pattern = "^([^:]+):(%d+):(%d+):(.*)$"

	-- emits accumulated batch to ui callback
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
		on_stdout = function(_, data)
			if not is_current(token) or not data then
				return
			end

			-- early exit if already hit max results
			if truncated then
				return
			end

			for i = 1, #data do
				local line = data[i]
				if line ~= "" then
					-- check limit before expensive parsing
					if result_count >= max_results then
						truncated = true
						emit_batch() -- flush remaining results
						pcall(vim.fn.jobstop, job_id)
						return -- exit immediately to avoid further processing
					end

					-- parse ripgrep output line
					local filename, lnum, col, text = line:match(pattern)
					if filename then
						result_count = result_count + 1
						local result = {
							filename = filename,
							lnum = tonumber(lnum),
							col = tonumber(col),
							text = text,
						}
						results[result_count] = result
						batch[#batch + 1] = result

						-- emit batch when full for progressive ui updates
						if #batch >= batch_size then
							emit_batch()
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
						on_complete(results, exit_code, truncated)
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
				on_complete({}, -1, false)
			end)
		end
		return job_id
	end

	active_job = job_id
	active_token = token
	return job_id
end

-- Synchronous ripgrep runner (blocks up to 5s)
function M.run_ripgrep(search, opts)
	if not search or search == "" then
		return {}
	end

	opts = opts or {}

	local cmd = {
		opts.rg_binary or "rg",
		"--color=never",
		"--no-heading",
		"--line-number",
		"--column",
		"--vimgrep",
		"--sort=path",
	}

	if opts.literal == true then
		cmd[#cmd + 1] = "--fixed-strings"
	end

	if opts.smart_case ~= false then
		cmd[#cmd + 1] = "--smart-case"
	end

	cmd[#cmd + 1] = search
	cmd[#cmd + 1] = opts.cwd or uv.cwd()

	local results = {}
	local pattern = "^([^:]+):(%d+):(%d+):(.*)$"

	local job_id = vim.fn.jobstart(cmd, {
		stdout_buffered = true,
		on_stdout = function(_, data)
			if data then
				for i = 1, #data do
					local line = data[i]
					if line ~= "" then
						local filename, lnum, col, text = line:match(pattern)
						if filename then
							results[#results + 1] = {
								filename = filename,
								lnum = tonumber(lnum),
								col = tonumber(col),
								text = text,
							}
						end
					end
				end
			end
		end,
	})

	vim.fn.jobwait({ job_id }, 5000)
	return results
end

return M
