local Buffer = require("tzpl.buffer")
local uv = vim.uv
local M = {}

M.stdin = nil
M.handle = nil
M.pid = nil
M.output_buf = nil

local function post(str)
	M.output_buf:append(str)
end

local function postln(str)
	M.output_buf:append(str .. "\n")
end

local function clear_ouput()
	vim.api.nvim_buf_set_lines(M.output_buf.bufnr, 0, -1, false, { "" })
end

local function eval(source)
	if not source then
		return
	end
	local terminated = source .. "\n%%" .. "\n"
	M.stdin:write(terminated)
end

local function eval_buf()
	local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
	local str = table.concat(lines, "\n")
	eval(str)
end

local function eval_line()
	local line = vim.api.nvim_get_current_line()
	eval(line)
end

local function eval_selection()
	local start = vim.fn.getpos(".")
	local stop = vim.fn.getpos("v")
	local lines = vim.fn.getregion(start, stop, { type = vim.fn.mode() or "v" })
	eval(table.concat(lines, "\n"))
end

local function is_empty_line(n)
	local line = vim.api.nvim_buf_get_lines(0, n, n + 1, true)
	if line[1] == "" then
		return true
	else
		return false
	end
end

local function eval_block()
	if vim.api.nvim_get_current_line() == "" then
		return
	end

	local row, _ = unpack(vim.api.nvim_win_get_cursor(0))
	local block_start = row - 1

	-- go up until beginning or empty line
	while block_start > 0 and not is_empty_line(block_start - 1) do
		block_start = block_start - 1
	end

	-- go down until EOF or empty line
	local line_count = vim.api.nvim_buf_line_count(0)
	local block_end = row
	while block_end < line_count and not is_empty_line(block_end) do
		block_end = block_end + 1
	end

	local lines = vim.api.nvim_buf_get_lines(0, block_start, block_end, true)
	eval(table.concat(lines, "\n"))
end

local function set_keymaps()
	local map = function(spec, fun, opts)
		vim.keymap.set(spec.mode, spec.key, fun, opts)
	end

	map(M.opts.keymaps.eval_buf, eval_buf)
	map(M.opts.keymaps.eval_line, eval_line)
	map(M.opts.keymaps.eval_selection, eval_selection)
	map(M.opts.keymaps.eval_block, eval_block)

	map(M.opts.keymaps.clear_output, clear_ouput)
end

local function start()
	if M.handle then
		vim.notify("tzpl is already running", vim.log.levels.WARN)
		return
	end

	local stdin = uv.new_pipe()
	local stdout = uv.new_pipe()
	local stderr = uv.new_pipe()

	-- local env = vim.fn.environ()
	-- env["TZPL_EVAL_CELLS"] = "1"
	-- local env_list = {}
	-- for k, v in pairs(env) do
	-- 	env_list[#env_list + 1] = k .. "=" .. v
	-- end

	local handle, pid = uv.spawn(M.opts.cmd, {
		stdio = { stdin, stdout, stderr },
		args = M.opts.args,
		-- env = env_list,
	}, function(code, signal)
		vim.schedule(function()
			postln("exit code: " .. code .. ", exit signal: " .. signal)
		end)

		M.handle:close(function()
			M.handle = nil
			M.pid = nil
		end)
	end)

	if not handle then
		vim.notify("tzpl could not start.", vim.log.levels.ERROR)
		return
	end

	local source_win = vim.api.nvim_get_current_win()
	M.output_buf:close_windows()
	M.output_buf:show({ split = "v" })
	postln("-- Tzopilotl. Shift+Enter: eval line, Ctrl+Enter: eval block, Ctrl+Shift+Enter: eval file.")
	vim.api.nvim_set_current_win(source_win)

	stdout:read_start(function(err, data)
		assert(not err, err)
		if data then
			vim.schedule(function()
				post(data)
			end)
		else
			return
		end
	end)

	stderr:read_start(function(err, data)
		assert(not err, err)
		if data then
			vim.schedule(function()
				post(data)
			end)
		else
			return
		end
	end)

	M.handle = handle
	M.pid = pid
	M.stdin = stdin
end

local function stop()
	if not M.handle then
		vim.notify("tzpl is not running", vim.log.levels.WARN)
		return
	end
	post("Shutting down...")
	M.stdin:shutdown()
end

function M.setup(opts)
	M.opts = vim.tbl_deep_extend("force", {
		cmd = "tzpl_app",
		args = { "--nogui", "--stdio" },
		env = {},
		keymaps = {
			eval_line = { mode = { "n", "i" }, key = "<S-CR>" },
			eval_block = { mode = "n", key = "<C-CR>" },
			eval_selection = { mode = "v", key = "<C-CR>" },
			eval_buf = { mode = { "n", "i" }, key = "<C-S-CR>" },
			clear_output = { mode = "n", key = "<C-S-x>" },
		},
	}, opts or {})

	vim.api.nvim_create_user_command("TzplStart", start, {})
	vim.api.nvim_create_user_command("TzplStop", stop, {})
	vim.api.nvim_create_user_command("TzplEvalLine", eval_line, {})
	vim.api.nvim_create_user_command("TzplEvalBlock", eval_block, {})
	vim.api.nvim_create_user_command("TzplEvalBuf", eval_buf, {})
	vim.api.nvim_create_user_command("TzplClear", clear_ouput, {})

	set_keymaps()

	vim.api.nvim_create_autocmd("FileType", {
		pattern = "tzpl",
		callback = function()
			vim.opt_local.commentstring = "-- %s"
		end,
	})

	M.output_buf = Buffer.new({ scratch = true })
end

return M
