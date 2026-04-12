-- Diff review UI: file list + side-by-side diff with extmark highlights.
--
-- Layout:
--   [file list]  |  [diff view]
--   narrow left     wide right
--
-- Keymaps (in diff view):
--   a / <leader>a   Accept current hunk (mark green)
--   r / <leader>r   Reject current hunk (revert on disk, mark red)
--   q               Close diff view
--   <CR> in file list   Show diff for that file

local actions_mod = require("neovim-cursor.diff.actions")
local diff_state = require("neovim-cursor.diff.state")
local log = require("neovim-cursor.log")

local M = {}

local ns = vim.api.nvim_create_namespace("neovim_cursor_diff")

local function setup_highlights()
	vim.api.nvim_set_hl(0, "CursorDiffAccepted", { default = true, bg = "#1a3a1a" })
	vim.api.nvim_set_hl(0, "CursorDiffRejected", { default = true, bg = "#3a1a1a" })
	vim.api.nvim_set_hl(0, "CursorDiffAdd", { default = true, bg = "#1a2a1a" })
	vim.api.nvim_set_hl(0, "CursorDiffDel", { default = true, bg = "#2a1a1a" })
	vim.api.nvim_set_hl(0, "CursorDiffFileHeader", { default = true, bold = true, underline = true })
	vim.api.nvim_set_hl(0, "CursorDiffTurnHeader", { default = true, bold = true, fg = "#7aa2f7" })
end

local function get_file_icon(path)
	local ok, devicons = pcall(require, "nvim-web-devicons")
	if not ok or not devicons then
		return "", "Normal"
	end
	local filename = vim.fn.fnamemodify(path, ":t")
	local extension = vim.fn.fnamemodify(path, ":e")
	local icon, hl = devicons.get_icon(filename, extension, { default = true })
	return icon or "", hl or "Normal"
end

-- Read current file content from disk (returns string or nil for new files).
local function read_file(path)
	local f = io.open(path, "r")
	if not f then
		return nil
	end
	local content = f:read("*a")
	f:close()
	return content
end

-- Build the old/new text pair for an edit so we can diff them.
local function build_diff_pair(edit)
	if edit.type == "str_replace" then
		return edit.old_string, edit.new_string
	elseif edit.type == "write" then
		local current = read_file(edit.path)
		return current or "", edit.content
	elseif edit.type == "apply_patch" then
		return "(patch content — see raw patch below)", edit.patch
	end
	return "", ""
end

-- View-local rendering state (buffers, windows, cursor tracking).
local view = {
	file_buf = nil,
	file_win = nil,
	diff_buf = nil,
	diff_win = nil,
	file_order = {},
	by_file = {},
	current_file = nil,
	hunk_ranges = {},
	state_listener_id = nil,
}

local function close_view()
	local bufs = { view.file_buf, view.diff_buf }
	local wins = { view.file_win, view.diff_win }

	for _, w in ipairs(wins) do
		if w and vim.api.nvim_win_is_valid(w) then
			pcall(vim.api.nvim_win_close, w, true)
		end
	end
	for _, b in ipairs(bufs) do
		if b and vim.api.nvim_buf_is_valid(b) then
			pcall(vim.api.nvim_buf_delete, b, { force = true })
		end
	end

	view.file_buf = nil
	view.file_win = nil
	view.diff_buf = nil
	view.diff_win = nil
end

-- Rebuild the file-centric grouping from state.
local function sync_from_state()
	view.by_file, view.file_order = diff_state.all_edits_by_file()
end

local function render_file_list()
	if not view.file_buf or not vim.api.nvim_buf_is_valid(view.file_buf) then
		return
	end

	sync_from_state()

	local lines = {}
	for _, fp in ipairs(view.file_order) do
		local entries = view.by_file[fp] or {}
		local accepted = 0
		local rejected = 0
		local pending = 0
		for _, entry in ipairs(entries) do
			local s = diff_state.get_status(entry.edit)
			if s == "accepted" then
				accepted = accepted + 1
			elseif s == "rejected" then
				rejected = rejected + 1
			else
				pending = pending + 1
			end
		end

		local icon, _ = get_file_icon(fp)
		local short = vim.fn.fnamemodify(fp, ":~:.")
		local status_str = ""
		if pending == 0 then
			status_str = (rejected > 0 and accepted > 0) and " [partial]"
				or (accepted > 0 and " [done]" or " [rejected]")
		else
			status_str = string.format(" [%d/%d]", accepted + rejected, #entries)
		end
		table.insert(lines, string.format("%s %s%s", icon, short, status_str))
	end

	vim.bo[view.file_buf].modifiable = true
	vim.api.nvim_buf_set_lines(view.file_buf, 0, -1, false, lines)
	vim.bo[view.file_buf].modifiable = false
end

local function render_diff(filepath)
	if not view.diff_buf or not vim.api.nvim_buf_is_valid(view.diff_buf) then
		return
	end

	view.current_file = filepath
	view.hunk_ranges = {}
	vim.api.nvim_buf_clear_namespace(view.diff_buf, ns, 0, -1)

	local file_entries = view.by_file[filepath] or {}
	local lines = {}
	local short = vim.fn.fnamemodify(filepath, ":~:.")
	table.insert(lines, "File: " .. short)
	table.insert(lines, string.rep("─", 60))
	table.insert(lines, "")

	-- Track which turn header we last rendered to avoid duplicates.
	local last_turn_num = nil
	local edit_counter = 0

	for _, entry in ipairs(file_entries) do
		local edit = entry.edit
		local turn = entry.turn
		edit_counter = edit_counter + 1

		-- Render turn separator when we enter a new turn.
		if turn and turn.turn_num ~= last_turn_num then
			last_turn_num = turn.turn_num
			local turn_label = string.format(
				"════ Turn %d: %s ════",
				turn.turn_num,
				turn.prompt
			)
			table.insert(lines, turn_label)
			table.insert(lines, "")
		end

		local hunk_start = #lines
		local status = diff_state.get_status(edit) or "pending"
		local header = string.format(
			"── Edit %d [%s] ── %s",
			edit_counter,
			status,
			edit.type
		)
		table.insert(lines, header)
		table.insert(lines, "")

		local old_text, new_text = build_diff_pair(edit)
		local diff_str = actions_mod.compute_diff(old_text, new_text)

		if diff_str ~= "" then
			for _, dl in ipairs(vim.split(diff_str, "\n")) do
				table.insert(lines, dl)
			end
		else
			table.insert(lines, "(no diff)")
		end

		table.insert(lines, "")
		local hunk_end = #lines - 1

		table.insert(view.hunk_ranges, {
			edit = edit,
			edit_index = edit_counter,
			start_line = hunk_start,
			end_line = hunk_end,
		})
	end

	if #file_entries == 0 then
		table.insert(lines, "(no edits for this file)")
	end

	vim.bo[view.diff_buf].modifiable = true
	vim.api.nvim_buf_set_lines(view.diff_buf, 0, -1, false, lines)
	vim.bo[view.diff_buf].modifiable = false

	-- Diff line highlights.
	for lnum = 0, #lines - 1 do
		local line = lines[lnum + 1]
		if line:match("^%+") and not line:match("^%+%+%+") then
			vim.api.nvim_buf_add_highlight(view.diff_buf, ns, "CursorDiffAdd", lnum, 0, -1)
		elseif line:match("^%-") and not line:match("^%-%-%-") then
			vim.api.nvim_buf_add_highlight(view.diff_buf, ns, "CursorDiffDel", lnum, 0, -1)
		elseif line:match("^── Edit") then
			vim.api.nvim_buf_add_highlight(view.diff_buf, ns, "CursorDiffFileHeader", lnum, 0, -1)
		elseif line:match("^════ Turn") then
			vim.api.nvim_buf_add_highlight(view.diff_buf, ns, "CursorDiffTurnHeader", lnum, 0, -1)
		end
	end

	M._apply_status_highlights()
end

function M._apply_status_highlights()
	for _, hunk in ipairs(view.hunk_ranges) do
		local status = diff_state.get_status(hunk.edit)
		local hl = nil
		if status == "accepted" then
			hl = "CursorDiffAccepted"
		elseif status == "rejected" then
			hl = "CursorDiffRejected"
		end
		if hl then
			for lnum = hunk.start_line, math.min(hunk.end_line, vim.api.nvim_buf_line_count(view.diff_buf) - 1) do
				vim.api.nvim_buf_add_highlight(view.diff_buf, ns, hl, lnum, 0, -1)
			end
		end
	end
end

local function get_hunk_at_cursor()
	if not view.diff_win or not vim.api.nvim_win_is_valid(view.diff_win) then
		return nil
	end
	local cursor = vim.api.nvim_win_get_cursor(view.diff_win)
	local row = cursor[1] - 1

	for _, hunk in ipairs(view.hunk_ranges) do
		if row >= hunk.start_line and row <= hunk.end_line then
			return hunk
		end
	end
	return nil
end

local function accept_hunk()
	local hunk = get_hunk_at_cursor()
	if not hunk then
		vim.notify("No hunk under cursor", vim.log.levels.WARN)
		return
	end
	if diff_state.get_status(hunk.edit) then
		vim.notify("Hunk already " .. diff_state.get_status(hunk.edit), vim.log.levels.INFO)
		return
	end

	actions_mod.accept(hunk.edit)
	diff_state.set_status(hunk.edit, "accepted")
	vim.notify(
		"Accepted edit " .. hunk.edit_index .. " on " .. vim.fn.fnamemodify(hunk.edit.path, ":t"),
		vim.log.levels.INFO
	)
	render_diff(view.current_file)
	render_file_list()
end

local function reject_hunk()
	local hunk = get_hunk_at_cursor()
	if not hunk then
		vim.notify("No hunk under cursor", vim.log.levels.WARN)
		return
	end
	if diff_state.get_status(hunk.edit) then
		vim.notify("Hunk already " .. diff_state.get_status(hunk.edit), vim.log.levels.INFO)
		return
	end

	local ok = actions_mod.reject(hunk.edit)
	if ok then
		diff_state.set_status(hunk.edit, "rejected")
		vim.notify(
			"Rejected edit " .. hunk.edit_index .. " on " .. vim.fn.fnamemodify(hunk.edit.path, ":t"),
			vim.log.levels.INFO
		)
	else
		vim.notify("Could not revert edit " .. hunk.edit_index, vim.log.levels.ERROR)
	end
	render_diff(view.current_file)
	render_file_list()
end

local function select_file_at_cursor()
	if not view.file_win or not vim.api.nvim_win_is_valid(view.file_win) then
		return
	end
	local cursor = vim.api.nvim_win_get_cursor(view.file_win)
	local idx = cursor[1]
	if idx <= #view.file_order then
		render_diff(view.file_order[idx])
		if view.diff_win and vim.api.nvim_win_is_valid(view.diff_win) then
			vim.api.nvim_set_current_win(view.diff_win)
		end
	end
end

--- Refresh the view in-place when state changes (e.g. new turn arrived).
local function refresh_view()
	if not view.diff_buf or not vim.api.nvim_buf_is_valid(view.diff_buf) then
		return
	end
	sync_from_state()
	render_file_list()
	if view.current_file then
		render_diff(view.current_file)
	end
end

--- Open the diff review view.
--- @param session table|nil If provided, loads edits from this session into state.
---   When nil, shows whatever is already in diff_state (watcher flow).
function M.open(session)
	setup_highlights()
	close_view()

	if session then
		diff_state.reset()
		diff_state.set_session_id(session.id)

		local parser = require("neovim-cursor.diff.parser")
		local turns = parser.parse_turns(session.path)
		for _, turn in ipairs(turns) do
			diff_state.add_turn(turn.edits, turn.prompt)
		end
	end

	local turns = diff_state.get_turns()
	if #turns == 0 then
		local msg = session and ("No file edits found in session " .. session.id)
			or "No pending edits to review"
		vim.notify(msg, vim.log.levels.INFO)
		return
	end

	sync_from_state()
	view.current_file = view.file_order[1]

	-- File list buffer (left, narrow)
	view.file_buf = vim.api.nvim_create_buf(false, true)
	vim.bo[view.file_buf].bufhidden = "wipe"
	vim.bo[view.file_buf].buftype = "nofile"
	vim.bo[view.file_buf].swapfile = false

	-- Diff buffer (right, wide)
	view.diff_buf = vim.api.nvim_create_buf(false, true)
	vim.bo[view.diff_buf].bufhidden = "wipe"
	vim.bo[view.diff_buf].buftype = "nofile"
	vim.bo[view.diff_buf].swapfile = false
	vim.bo[view.diff_buf].filetype = "diff"

	-- Create layout: vertical split
	vim.cmd("botright vnew")
	view.diff_win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(view.diff_win, view.diff_buf)

	vim.cmd("leftabove vnew")
	view.file_win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(view.file_win, view.file_buf)
	vim.api.nvim_win_set_width(view.file_win, 35)
	vim.wo[view.file_win].winfixwidth = true
	vim.wo[view.file_win].number = false
	vim.wo[view.file_win].relativenumber = false
	vim.wo[view.file_win].cursorline = true

	vim.wo[view.diff_win].number = false
	vim.wo[view.diff_win].relativenumber = false
	vim.wo[view.diff_win].wrap = false

	render_file_list()
	render_diff(view.current_file)

	-- File list keymaps
	vim.keymap.set("n", "<CR>", select_file_at_cursor, { buffer = view.file_buf, silent = true })
	vim.keymap.set("n", "q", close_view, { buffer = view.file_buf, silent = true })

	-- Diff view keymaps
	vim.keymap.set("n", "a", accept_hunk, { buffer = view.diff_buf, silent = true })
	vim.keymap.set("n", "<leader>a", accept_hunk, { buffer = view.diff_buf, silent = true })
	vim.keymap.set("n", "r", reject_hunk, { buffer = view.diff_buf, silent = true })
	vim.keymap.set("n", "<leader>r", reject_hunk, { buffer = view.diff_buf, silent = true })
	vim.keymap.set("n", "q", close_view, { buffer = view.diff_buf, silent = true })

	vim.api.nvim_set_current_win(view.diff_win)

	-- Auto-refresh when state changes (e.g. watcher adds a new turn).
	diff_state.on_change(refresh_view)

	log.debug("diff.view", "opened review" .. (session and (" for session " .. session.id) or " (pending)"))
end

log.debug("diff.view", "loaded")

return M
