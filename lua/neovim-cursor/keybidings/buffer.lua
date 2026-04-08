-- Buffer-local keymaps (agent terminal, floating prompts, etc.).

local M = {}

--- Buffer-local maps for an agent terminal (terminal mode).
---@param bufnr integer
---@param keybindings table|nil
function M.setup_agent_terminal_buffer(bufnr, keybindings)
	local kb = keybindings or {}
	local next_w = kb.next_window or "<S-n>"
	local prev_w = kb.prev_window or "<S-l>"

	vim.api.nvim_buf_set_keymap(bufnr, "t", "<Esc>", "<C-\\><C-n>", {
		noremap = true,
		silent = true,
		desc = "Exit terminal mode (Normal mode in buffer)",
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
		"<C-r>",
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
end

--- Buffer-local maps for the quick-question floating prompt.
---@param bufnr integer
---@param close_fn function
function M.setup_quick_question_float(bufnr, close_fn)
	vim.keymap.set("n", "<Esc>", close_fn, { buffer = bufnr, silent = true })
	vim.keymap.set("i", "<Esc>", close_fn, { buffer = bufnr, silent = true })
end

return M
