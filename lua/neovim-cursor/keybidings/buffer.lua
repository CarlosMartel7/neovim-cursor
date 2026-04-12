-- Buffer-local keymaps (agent terminal, floating prompts, etc.).

local M = {}

local function open_agent_help(next_w, prev_w)
	local lines = {
		"Agent Terminal Keybindings",
		"",
		"Terminal mode:",
		"  <Esc>      Loading: jump to other window / otherwise Normal mode",
		"  " .. next_w .. "      Focus next window",
		"  " .. prev_w .. "      Focus previous window",
		"  <C-n>      Create new agent terminal",
		"  <C-t>      Select agent terminal",
		"  <C-l>      Rename current agent terminal",
		"",
		"Normal mode (inside terminal buffer):",
		"  ?          Open this help menu",
		"  w          Leave agent window",
		"  d          Delete current agent window",
		"  q          Hide/quit agent window",
		"  l          Change agent terminal location",
		"  i          Enter insert mode inside of the promp field.",
		"",
		"Press q or <Esc> to close this help.",
	}

	local max_width = 0
	for _, line in ipairs(lines) do
		max_width = math.max(max_width, vim.fn.strdisplaywidth(line))
	end

	local width = math.min(max_width + 4, math.floor(vim.o.columns * 0.85))
	local height = math.min(#lines + 2, math.floor(vim.o.lines * 0.85))
	local row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1)
	local col = math.max(0, math.floor((vim.o.columns - width) / 2))

	local help_buf = vim.api.nvim_create_buf(false, true)
	vim.bo[help_buf].bufhidden = "wipe"
	vim.bo[help_buf].buftype = "nofile"
	vim.bo[help_buf].swapfile = false

	local help_win = vim.api.nvim_open_win(help_buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		style = "minimal",
		border = "rounded",
		title = " Agent Help ",
		title_pos = "center",
	})

	vim.api.nvim_buf_set_lines(help_buf, 0, -1, false, lines)
	vim.bo[help_buf].modifiable = false
	vim.bo[help_buf].readonly = true
	vim.wo[help_win].cursorline = true

	local close_help = function()
		if vim.api.nvim_win_is_valid(help_win) then
			vim.api.nvim_win_close(help_win, true)
		end
	end

	vim.keymap.set("n", "q", close_help, { buffer = help_buf, silent = true })
	vim.keymap.set("n", "<Esc>", close_help, { buffer = help_buf, silent = true })
end

--- Buffer-local maps for an agent terminal (terminal mode).
---@param bufnr integer
---@param keybindings table|nil
function M.setup_agent_terminal_buffer(bufnr, keybindings)
	local kb = keybindings or {}
	local next_w = kb.next_window or "<S-n>"
	local prev_w = kb.prev_window or "<S-l>"

	vim.keymap.set("t", "<Esc>", function()
		local terminal = require("neovim-cursor.windows.terminal")
		local keys
		if terminal.is_loading() then
			keys = "<C-\\><C-n><C-w>w"
		else
			keys = "<C-\\><C-n>"
		end
		local feed = vim.api.nvim_replace_termcodes(keys, true, false, true)
		vim.api.nvim_feedkeys(feed, "n", false)
	end, {
		buffer = bufnr,
		silent = true,
		desc = "Exit terminal mode (or jump window while loading)",
	})

	vim.api.nvim_buf_set_keymap(bufnr, "t", next_w, "<C-\\><C-n><C-w>w", {
		noremap = true,
		silent = true,
		desc = "Focus next window",
	})

	vim.api.nvim_buf_set_keymap(bufnr, "t", prev_w, "<C-\\><C-n><C-w>W", {
		noremap = true,
		silent = true,
		desc = "Focus previous window",
	})

	vim.api.nvim_buf_set_keymap(
		bufnr,
		"t",
		"<C-n>",
		'<C-\\><C-n>:lua require("neovim-cursor").new_terminal_from_terminal_handler()<CR>',
		{
			noremap = true,
			silent = true,
			desc = "Create new agent terminal (hide current first)",
		}
	)

	vim.api.nvim_buf_set_keymap(
		bufnr,
		"t",
		"<C-l>",
		'<C-\\><C-n>:lua require("neovim-cursor").rename_terminal_handler()<CR>',
		{
			noremap = true,
			silent = true,
			desc = "Rename current agent window",
		}
	)

	vim.api.nvim_buf_set_keymap(
		bufnr,
		"t",
		"<C-t>",
		'<C-\\><C-n>:lua require("neovim-cursor").select_terminal_handler()<CR>',
		{
			noremap = true,
			silent = true,
			desc = "Select agent terminal",
		}
	)

	vim.api.nvim_buf_set_keymap(bufnr, "n", "w", "<C-w>w", {
		noremap = true,
		silent = true,
		desc = "Leave agent window",
	})

	vim.api.nvim_buf_set_keymap(bufnr, "n", "d", '<Cmd>lua require("neovim-cursor").delete_terminal_handler()<CR>', {
		noremap = true,
		silent = true,
		desc = "Delete agent window",
	})

	vim.api.nvim_buf_set_keymap(bufnr, "n", "q", '<Cmd>lua require("neovim-cursor").toggle_terminal_handler()<CR>', {
		noremap = true,
		silent = true,
		desc = "Quit agent window",
	})

	vim.api.nvim_buf_set_keymap(bufnr, "n", "l", '<Cmd>lua require("neovim-cursor").change_location_handler()<CR>', {
		noremap = true,
		silent = true,
		desc = "Change agent terminal location",
	})

	vim.keymap.set("n", "?", function()
		open_agent_help(next_w, prev_w)
	end, {
		buffer = bufnr,
		silent = true,
		desc = "Open agent keybindings help",
	})
end

--- Buffer-local maps for the quick-question floating prompt.
---@param bufnr integer
---@param close_fn function
function M.setup_quick_question_float(bufnr, close_fn)
	vim.keymap.set("n", "<Esc>", close_fn, { buffer = bufnr, silent = true })
	vim.keymap.set("i", "<Esc>", close_fn, { buffer = bufnr, silent = true })
end

return M
