-- Full-window loading overlay on top of a new agent terminal.
-- Keeps the split from looking empty while `cursor agent` boots and dismisses
-- as soon as the terminal reports agent activity.

local log = require("neovim-cursor.log")

local M = {}

local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local ANSI_ESCAPE_PATTERN = "\27%[[0-9;?]*[ -/]*[@-~]"

local function strip_ansi(s)
	return (s:gsub(ANSI_ESCAPE_PATTERN, ""))
end

-- Only treat substantial terminal output as "agent is ready" activity.
-- This prevents accidental dismissal when users press random keys while loading.
function M.should_dismiss_from_data(data)
	if type(data) ~= "table" then
		return false
	end

	for _, chunk in ipairs(data) do
		if type(chunk) == "string" then
			local cleaned = strip_ansi(chunk):gsub("[%z\1-\31\127]", ""):gsub("%s+", "")
			if #cleaned >= 8 then
				return true
			end
		end
	end

	return false
end

function M.is_active(term)
	return term
		and term._loading_overlay
		and term._loading_overlay.win
		and vim.api.nvim_win_is_valid(term._loading_overlay.win)
end

function M.dismiss(term)
	if not term or not term._loading_overlay then
		return
	end
	local o = term._loading_overlay
	term._loading_overlay = nil

	if o.augroup then
		pcall(vim.api.nvim_del_augroup_by_id, o.augroup)
	end
	if o.spinner_timer then
		pcall(function()
			o.spinner_timer:stop()
		end)
		pcall(function()
			o.spinner_timer:close()
		end)
	end

	if o.win and vim.api.nvim_win_is_valid(o.win) then
		pcall(vim.api.nvim_win_close, o.win, true)
	end
	if o.buf and vim.api.nvim_buf_is_valid(o.buf) then
		pcall(vim.api.nvim_buf_delete, o.buf, { force = true })
	end
end

function M.on_agent_activated(term)
	if not term or not term._loading_overlay then
		return
	end

	log.debug("loading_overlay", "dismiss on agent activation", { term_buf = term.buf })
	M.dismiss(term)
end

---@param term table terminal instance (.buf, .win)
---@param config table merged plugin config
function M.attach(term, config)
	local tcfg = config.terminal or {}
	if tcfg.loading_screen == false then
		return
	end

	local anchor_win = term.win
	local term_buf = term.buf
	if not anchor_win or not vim.api.nvim_win_is_valid(anchor_win) then
		return
	end

	M.dismiss(term)

	local w = vim.api.nvim_win_get_width(anchor_win)
	local h = vim.api.nvim_win_get_height(anchor_win)

	local message = tcfg.loading_message or "Starting Cursor agent…"

	vim.api.nvim_set_hl(0, "NeovimCursorLoading", { default = true, link = "Normal" })

	local obuf = vim.api.nvim_create_buf(false, true)
	vim.bo[obuf].bufhidden = "wipe"
	vim.bo[obuf].modifiable = true

	local spinner_i = 1
	local function redraw()
		if not vim.api.nvim_buf_is_valid(obuf) then
			return
		end
		if vim.api.nvim_win_is_valid(anchor_win) then
			w = vim.api.nvim_win_get_width(anchor_win)
			h = vim.api.nvim_win_get_height(anchor_win)
		end
		local spin = SPINNER[spinner_i]
		spinner_i = spinner_i % #SPINNER + 1
		local lines = {}
		local mid = math.max(1, math.floor(h / 2))
		for r = 1, h do
			if r == mid then
				local text = string.format("  %s  %s", spin, message)
				local pad = math.max(0, math.floor((w - vim.fn.strdisplaywidth(text)) / 2))
				lines[r] = string.rep(" ", pad) .. text
			else
				lines[r] = ""
			end
		end
		vim.api.nvim_buf_set_lines(obuf, 0, -1, false, lines)
	end

	redraw()

	local win_opts = {
		relative = "win",
		win = anchor_win,
		width = w,
		height = h,
		row = 0,
		col = 0,
		style = "minimal",
		border = "none",
		focusable = false,
	}
	if vim.fn.has("nvim-0.9") == 1 then
		win_opts.zindex = 50
	end

	local float_win = vim.api.nvim_open_win(obuf, false, win_opts)
	vim.api.nvim_win_set_option(float_win, "wrap", false)
	vim.api.nvim_win_set_option(float_win, "winhl", "Normal:NeovimCursorLoading")
	pcall(vim.api.nvim_win_set_option, float_win, "winblend", 8)

	local o = {
		win = float_win,
		buf = obuf,
		augroup = nil,
		spinner_timer = nil,
	}
	term._loading_overlay = o

	local spinner_timer = vim.loop.new_timer()
	o.spinner_timer = spinner_timer
	spinner_timer:start(
		120,
		120,
		vim.schedule_wrap(function()
			if not term._loading_overlay or term._loading_overlay.win ~= float_win then
				spinner_timer:stop()
				return
			end
			if not vim.api.nvim_win_is_valid(float_win) then
				spinner_timer:stop()
				M.dismiss(term)
				return
			end
			if not vim.api.nvim_win_is_valid(anchor_win) then
				spinner_timer:stop()
				M.dismiss(term)
				return
			end
			redraw()
			local nw = vim.api.nvim_win_get_width(anchor_win)
			local nh = vim.api.nvim_win_get_height(anchor_win)
			pcall(vim.api.nvim_win_set_config, float_win, {
				relative = "win",
				win = anchor_win,
				width = nw,
				height = nh,
				row = 0,
				col = 0,
			})
		end)
	)

	local augroup = vim.api.nvim_create_augroup("NeovimCursorLoading" .. tostring(term_buf), { clear = true })
	o.augroup = augroup
	vim.api.nvim_create_autocmd("WinClosed", {
		group = augroup,
		pattern = tostring(anchor_win),
		callback = function()
			M.dismiss(term)
		end,
	})
	vim.api.nvim_create_autocmd({ "BufWipeout", "TermClose" }, {
		group = augroup,
		buffer = term_buf,
		callback = function()
			M.dismiss(term)
		end,
	})
end

log.debug("loading_overlay", "loaded")

return M
