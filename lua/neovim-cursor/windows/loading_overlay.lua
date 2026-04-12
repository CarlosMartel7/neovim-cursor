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
	local cwd = vim.fn.getcwd()
	local warn_text = "Be sure to be at the right location to retrieve your sessions later. You can use <Leader>al to change the agent location."

	vim.api.nvim_set_hl(0, "NeovimCursorLoading", { default = true, link = "Normal" })

	local obuf = vim.api.nvim_create_buf(false, true)
	vim.bo[obuf].bufhidden = "wipe"
	vim.bo[obuf].modifiable = true

	local spinner_i = 1
	local gap_after_main = tcfg.loading_overlay_gap or 3

	-- Break string into lines each with display width <= max_w (no ellipsis).
	local function wrap_hard(s, max_w)
		local out = {}
		if max_w < 1 or s == "" then
			return out
		end
		local pos = 0
		local total = vim.fn.strchars(s)
		while pos < total do
			local low, high = 1, total - pos
			local best = 1
			while low <= high do
				local mid = math.floor((low + high) / 2)
				local sub = vim.fn.strcharpart(s, pos, mid)
				if vim.fn.strdisplaywidth(sub) <= max_w then
					best = mid
					low = mid + 1
				else
					high = mid - 1
				end
			end
			local line = vim.fn.strcharpart(s, pos, best)
			table.insert(out, line)
			pos = pos + best
		end
		return out
	end

	local function wrap_words(text, max_w)
		local lines = {}
		local line = ""
		for word in string.gmatch(text, "%S+") do
			local candidate = line == "" and word or (line .. " " .. word)
			if vim.fn.strdisplaywidth(candidate) <= max_w then
				line = candidate
			else
				if line ~= "" then
					table.insert(lines, line)
				end
				if vim.fn.strdisplaywidth(word) > max_w then
					vim.list_extend(lines, wrap_hard(word, max_w))
					line = ""
				else
					line = word
				end
			end
		end
		if line ~= "" then
			table.insert(lines, line)
		end
		return lines
	end

	local function center_line_text(text)
		local dw = vim.fn.strdisplaywidth(text)
		local pad = math.max(0, math.floor((w - dw) / 2))
		return string.rep(" ", pad) .. text
	end

	local function build_block(spin, gap)
		local max_text_w = math.max(4, w - 2)
		local main = string.format("  %s  %s", spin, message)
		local blk = { center_line_text(main) }
		for _ = 1, gap do
			table.insert(blk, "")
		end
		vim.list_extend(blk, vim.tbl_map(center_line_text, wrap_words(warn_text, max_text_w)))
		table.insert(blk, "")
		table.insert(blk, center_line_text("Opening at:"))
		vim.list_extend(blk, vim.tbl_map(center_line_text, wrap_words(cwd, max_text_w)))
		return blk
	end

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
		for r = 1, h do
			lines[r] = ""
		end
		local gap = math.max(0, gap_after_main)
		local block
		repeat
			block = build_block(spin, gap)
			if #block <= h or gap == 0 then
				break
			end
			gap = gap - 1
		until false
		if #block > h then
			local clipped = {}
			for i = 1, h do
				clipped[i] = block[i]
			end
			block = clipped
		end
		local start_row = math.max(1, math.floor((h - #block) / 2) + 1)
		for i = 1, #block do
			local r = start_row + i - 1
			if r <= h then
				lines[r] = block[i]
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
