-- buba.pi: send the current selection from Neovim to a running pi session.
--
-- Requires the pi extension ~/.pi/agent/extensions/nvim-bridge.ts, which
-- listens on a per-project Unix socket:
--   $XDG_RUNTIME_DIR/pi-bridge/nvim-<sha256(realpath(cwd))[:16]>.sock
-- Start `pi` in the project root, select code in visual mode, hit <leader>i…
-- Keymaps live in lua/buba/remap.lua.

local M = {}

local uv = vim.uv

-- vim.fs.realpath only exists on newer nvim; uv.fs_realpath works everywhere.
local function realpath(p)
	if not p then
		return p
	end
	local ok, res = pcall(uv.fs_realpath, p)
	return (ok and res) or p
end

local MAX_WHOLE_FILE_LINES = 400

local function bridge_dir()
	local xdg = os.getenv("XDG_RUNTIME_DIR")
	if xdg and xdg ~= "" then
		return xdg .. "/pi-bridge"
	end
	return ("/tmp/pi-bridge-%d"):format(uv.os_getuid())
end

local function socket_path()
	local cwd = uv.cwd()
	local real = realpath(cwd)
	return ("%s/nvim-%s.sock"):format(bridge_dir(), vim.fn.sha256(real):sub(1, 16))
end

-- Returns code, start_line, end_line, note
-- Visual keymaps exit visual mode (<Esc>) before calling send, so the '< '>
-- marks are committed and visualmode() reflects the selection that just ended.
local function get_selection(visual)
	if visual then
		local vmode = vim.fn.visualmode()
		if vmode == "" then
			return nil, nil, nil, "no selection found"
		end
		local s = vim.fn.getpos("'<")
		local e = vim.fn.getpos("'>")
		local sl, sc, el, ec = s[2], s[3], e[2], e[3]

		if sl > el then
			sl, el = el, sl
			sc, ec = ec, sc
		end
		if vmode == "\22" and sc > ec then
			sc, ec = ec, sc
		end

		local last_line = vim.api.nvim_buf_get_lines(0, el - 1, el, false)[1] or ""
		local end_col = math.min(ec, #last_line)
		if vmode == "V" then
			sc = 1
			end_col = #last_line
		end

		local lines = vim.api.nvim_buf_get_text(0, sl - 1, sc - 1, el - 1, end_col, {})
		return table.concat(lines, "\n"), sl, el, nil
	end

	-- Normal mode: send the whole buffer (truncated by the extension if huge).
	local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
	local n = #lines
	if n == 0 then
		return nil, nil, nil, "buffer is empty"
	end
	local code = table.concat(lines, "\n")
	local note = nil
	if n > MAX_WHOLE_FILE_LINES then
		code = table.concat(vim.list_slice(lines, 1, MAX_WHOLE_FILE_LINES), "\n")
		note = ("whole buffer sent, truncated to first %d of %d lines"):format(MAX_WHOLE_FILE_LINES, n)
	else
		note = "whole buffer sent"
	end
	return code, 1, n, note
end

local function build_payload(action, instruction, visual)
	local code, sl, el, note = get_selection(visual)
	if not code then
		return nil, note
	end

	local file = vim.api.nvim_buf_get_name(0)
	local payload = {
		action = action,
		file = file ~= "" and file or nil,
		start = sl,
		["end"] = el,
		lang = vim.bo.filetype ~= "" and vim.bo.filetype or nil,
		code = code,
		instruction = instruction,
		projectRoot = (realpath(uv.cwd()) or uv.cwd()),
	}

	local notes = {}
	if note then
		table.insert(notes, note)
	end
	if vim.bo.modified and file ~= "" then
		table.insert(notes, "buffer has unsaved changes; the code block reflects the current buffer state")
	end
	if #notes > 0 then
		payload.note = table.concat(notes, "; ")
	end

	return vim.json.encode(payload), nil
end

-- Connect to the bridge socket, send payload + "\n", wait for the JSON ack.
local function send_over_socket(payload, on_ack)
	local sock = socket_path()
	local client = assert(uv.new_pipe(false))
	local timer = assert(uv.new_timer())
	local buf = ""
	local done = false

	local function finish(msg, level)
		if done then
			return
		end
		done = true
		timer:stop()
		timer:close()
		pcall(function()
			client:read_stop()
			client:close()
		end)
		vim.schedule(function()
			vim.notify(msg, level, { title = "pi" })
		end)
	end

	timer:start(3000, 0, function()
		finish("timed out waiting for the pi bridge ack", vim.log.levels.WARN)
	end)

	client:connect(sock, function(err)
		if err then
			finish(
				"no pi session found for this project — start `pi` in the project root (" .. tostring(err) .. ")",
				vim.log.levels.WARN
			)
			return
		end

		client:read_start(function(rerr, chunk)
			if rerr then
				finish("bridge read error: " .. rerr, vim.log.levels.ERROR)
				return
			end
			if not chunk then
				finish("bridge closed without an ack", vim.log.levels.ERROR)
				return
			end
			buf = buf .. chunk
			local ok, ack = pcall(vim.json.decode, buf)
			if ok and type(ack) == "table" then
				on_ack(ack, finish)
			end
		end)

		client:write(payload .. "\n", function(werr)
			if werr then
				finish("bridge write error: " .. werr, vim.log.levels.ERROR)
			end
		end)
	end)
end

function M.send(action, instruction, visual)
	local encoded, problem = build_payload(action, instruction, visual)
	if not encoded then
		vim.notify("pi: " .. (problem or "nothing to send"), vim.log.levels.WARN, { title = "pi" })
		return
	end

	send_over_socket(encoded, function(ack, finish)
		if not ack.ok then
			finish("bridge error: " .. tostring(ack.error), vim.log.levels.ERROR)
			return
		end
		if ack.delivered == "editor" then
			finish("selection pasted into pi's editor — finish your prompt and submit", vim.log.levels.INFO)
		elseif ack.queued then
			finish("sent to pi (agent busy — queued as follow-up)", vim.log.levels.INFO)
		else
			finish("sent to pi", vim.log.levels.INFO)
		end
	end)
end

function M.explain(visual)
	M.send("explain", nil, visual)
end

function M.refactor(visual)
	M.send("refactor", nil, visual)
end

function M.tests(visual)
	M.send("tests", nil, visual)
end

function M.ask(visual)
	vim.ui.input({ prompt = "Ask pi about the selection: " }, function(value)
		if value and value ~= "" then
			M.send("custom", value, visual)
		end
	end)
end

function M.draft(visual)
	M.send("draft", nil, visual)
end

return M
