-- Search module - handles ripgrep search operations
local M = {}

function M.run_ripgrep(search, opts)
	if not search or search == "" then
		return {}
	end

	opts = opts or {}
	local cmd = { opts.rg_binary or "rg", "--color=never", "--no-heading", "--line-number", "--column" }

	if opts.literal == true then
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

	vim.fn.jobwait({ job_id }, 5000)
	return results
end

return M
