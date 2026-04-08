-- User-facing command and keymap handlers for neovim-cursor.
--
-- Key handlers:
-- - normal_mode(): Smart toggle (create first terminal or show last active)
-- - visual_mode(): Send visual selection to active agent
-- - new_terminal(): Create new agent terminal with prompt
-- - select_terminal(): Open fuzzy picker to select agent
-- - rename_terminal(): Rename active agent
--

local buffer_keybindings = require("neovim-cursor.keybidings.buffer")

local M = {}

local ctx = {
	config = nil,
	terminal = nil,
	tabs = nil,
	picker = nil,
}

local quick_question_state = {
	selection = nil,
}

function M.set_context(t)
	ctx.config = t.config
	ctx.terminal = t.terminal
	ctx.tabs = t.tabs
	ctx.picker = t.picker
end

-- Normal mode handler: smart toggle (create first terminal or show last active)
function M.normal_mode()
	local config = ctx.config
	local tabs = ctx.tabs
	local terminal = ctx.terminal
	if not tabs.has_terminals() then
		tabs.create_terminal(nil, config)
	else
		local last_id = tabs.get_last()
		if last_id then
			terminal.toggle(config, last_id)
		else
			tabs.create_terminal(nil, config)
		end
	end
end

function M.toggle_terminal()
	local config = ctx.config
	local tabs = ctx.tabs
	local terminal = ctx.terminal

	if tabs.has_terminals() then
		local last_id = tabs.get_last()
		terminal.toggle(config, last_id)
	end
end

-- Handler for creating a new terminal
function M.new_terminal()
	ctx.tabs.create_terminal(nil, ctx.config)
end

-- Handler for creating a new terminal from within terminal mode
-- By default hides the current terminal first so only one agent split is visible; with
-- multiple_windows, keeps existing splits and opens another from the current window.
function M.new_terminal_from_terminal()
	local config = ctx.config
	if not (config.terminal and config.terminal.multiple_windows) then
		ctx.terminal.hide()
	end

	vim.schedule(function()
		M.new_terminal()
	end)
end

-- Handler for selecting a terminal from picker
function M.select_terminal()
	local config = ctx.config
	ctx.picker.pick_terminal(config, function(selected_id)
		if selected_id then
			ctx.tabs.switch_to(selected_id, config)
		end
	end)
end

-- Handler for renaming the active terminal
function M.rename_terminal()
	local tabs = ctx.tabs
	local active_id = tabs.get_active()

	if not active_id then
		vim.notify("No active terminal to rename. Create one with <leader>an", vim.log.levels.WARN)
		return
	end

	local term = tabs.get_terminal(active_id)
	local current_name = term and term.name or ""

	local current_buf = vim.api.nvim_get_current_buf()
	local is_terminal_buf = vim.bo[current_buf].buftype == "terminal"

	vim.ui.input({
		prompt = "Rename agent window: ",
		default = current_name,
	}, function(input)
		if input and input ~= "" then
			if tabs.rename_terminal(active_id, input) then
				vim.notify("Terminal renamed to: " .. input, vim.log.levels.INFO)
				if is_terminal_buf then
					vim.schedule(function()
						vim.cmd("startinsert")
					end)
				end
			else
				vim.notify("Failed to rename terminal", vim.log.levels.ERROR)
			end
		elseif is_terminal_buf then
			vim.schedule(function()
				vim.cmd("startinsert")
			end)
		end
	end)
end

-- Handler for deleting the active terminal
function M.delete_terminal()
	local tabs = ctx.tabs
	local active_id = tabs.get_active()

	if not active_id then
		vim.notify("No active terminal to delete. Create one with <leader>an", vim.log.levels.WARN)
		return
	end

	if tabs.delete_terminal(active_id) then
		vim.notify("Deleted active Cursor Agent terminal", vim.log.levels.INFO)
	else
		vim.notify("Failed to delete active terminal", vim.log.levels.ERROR)
	end
end

-- Handler for listing all terminals
function M.list_terminals()
	local tabs = ctx.tabs
	local terminal = ctx.terminal
	local terminals = tabs.list_terminals()

	if #terminals == 0 then
		vim.notify("No terminals available. Create one with <leader>an", vim.log.levels.INFO)
		return
	end

	local active_id = tabs.get_active()
	local lines = { "Cursor Agent Terminals:", "" }

	for i, term in ipairs(terminals) do
		local status = terminal.is_running(term.id) and "running" or "stopped"
		local active_marker = (term.id == active_id) and "? " or "  "
		local age_seconds = os.time() - term.created_at
		local age_str

		if age_seconds < 60 then
			age_str = age_seconds .. "s"
		elseif age_seconds < 3600 then
			age_str = math.floor(age_seconds / 60) .. "m"
		else
			age_str = math.floor(age_seconds / 3600) .. "h"
		end

		table.insert(
			lines,
			string.format("%s%d. %s [%s] (created %s ago)", active_marker, i, term.name, status, age_str)
		)
	end

	table.insert(lines, "")
	table.insert(lines, string.format("Total: %d terminal(s)", #terminals))

	vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

-- Visual mode handler: toggle terminal and send selection
function M.visual_mode()
	local config = ctx.config
	local tabs = ctx.tabs
	local terminal = ctx.terminal
	local buf = vim.api.nvim_get_current_buf()
	local filepath = vim.api.nvim_buf_get_name(buf)

	local start_pos = vim.fn.getpos("'<")
	local end_pos = vim.fn.getpos("'>")
	local start_line = start_pos[2]
	local end_line = end_pos[2]

	if not tabs.has_terminals() then
		tabs.create_terminal(nil, config)
	else
		local last_id = tabs.get_last()
		if last_id then
			terminal.toggle(config, last_id)
		end
	end

	vim.defer_fn(function()
		local active_id = tabs.get_active()
		if active_id and terminal.is_running(active_id) then
			local text_to_send = "@" .. filepath .. ":" .. start_line .. "-" .. end_line
			terminal.send_text(text_to_send, active_id)
		end
	end, 100)
end

local function get_visual_selection_data()
	local buf = vim.api.nvim_get_current_buf()
	local filepath = vim.api.nvim_buf_get_name(buf)
	local start_pos = vim.fn.getpos("'<")
	local end_pos = vim.fn.getpos("'>")
	local start_line = start_pos[2]
	local start_col = start_pos[3]
	local end_line = end_pos[2]
	local end_col = end_pos[3]

	if start_line == 0 or end_line == 0 then
		return nil
	end

	if start_line > end_line or (start_line == end_line and start_col > end_col) then
		start_line, end_line = end_line, start_line
		start_col, end_col = end_col, start_col
	end

	local lines = vim.api.nvim_buf_get_lines(buf, start_line - 1, end_line, false)
	if #lines == 0 then
		return nil
	end

	lines[1] = string.sub(lines[1], math.max(start_col, 1))
	if #lines == 1 then
		lines[1] = string.sub(lines[1], 1, math.max(end_col - start_col + 1, 0))
	else
		lines[#lines] = string.sub(lines[#lines], 1, math.max(end_col, 0))
	end

	return {
		filepath = filepath,
		start_line = start_line,
		end_line = end_line,
		text = table.concat(lines, "\n"),
	}
end

local function ensure_agent_terminal()
	local config = ctx.config
	local tabs = ctx.tabs
	local terminal = ctx.terminal
	if not tabs.has_terminals() then
		tabs.create_terminal(nil, config)
	else
		local last_id = tabs.get_last()
		if last_id then
			terminal.toggle(config, last_id)
		else
			tabs.create_terminal(nil, config)
		end
	end
end

local function send_quick_question(question)
	local terminal = ctx.terminal
	local tabs = ctx.tabs
	local selection = quick_question_state.selection
	if not selection then
		vim.notify("No stored selection for quick question", vim.log.levels.WARN)
		return
	end

	ensure_agent_terminal()

	vim.defer_fn(function()
		local active_id = tabs.get_active()
		if not (active_id and terminal.is_running(active_id)) then
			vim.notify("Cursor agent terminal is not running", vim.log.levels.WARN)
			return
		end

		local context_ref = string.format("@%s (%d - %d)", selection.filepath, selection.start_line, selection.end_line)
		local payload = table.concat({
			"Use this code selection as context:",
			context_ref,
			"",
			question,
		}, "\n")

		terminal.send_text(payload, active_id)
	end, 100)
end

local function open_quick_question_float()
	local buf = vim.api.nvim_create_buf(false, true)
	local width = math.min(90, math.floor(vim.o.columns * 0.7))
	local height = 1
	local row = math.floor((vim.o.lines - height) / 2) - 1
	local col = math.floor((vim.o.columns - width) / 2)

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = math.max(row, 0),
		col = math.max(col, 0),
		style = "minimal",
		border = "rounded",
		title = " Quick Question ",
		title_pos = "center",
	})

	vim.bo[buf].buftype = "prompt"
	vim.bo[buf].bufhidden = "wipe"
	vim.fn.prompt_setprompt(buf, "Ask> ")

	vim.fn.prompt_setcallback(buf, function(input)
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end

		if not input or vim.trim(input) == "" then
			vim.notify("Quick question cancelled", vim.log.levels.INFO)
			return
		end

		send_quick_question(vim.trim(input))
	end)

	local close_float = function()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end

	buffer_keybindings.setup_quick_question_float(buf, close_float)

	vim.cmd("startinsert")
end

-- Visual mode handler: store selection and prompt user for a quick question.
function M.quick_question()
	local selection = get_visual_selection_data()
	if not selection then
		vim.notify("No visual selection found for quick question", vim.log.levels.WARN)
		return
	end

	quick_question_state.selection = selection
	open_quick_question_float()
end

return M
