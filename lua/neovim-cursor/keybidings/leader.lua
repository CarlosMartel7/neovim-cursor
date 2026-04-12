-- Global keymaps for neovim-cursor (<leader> and related normal/visual bindings).

local M = {}

local handlers = require("neovim-cursor.handlers")

local keybindings = {
	toggle = "<leader>ai",
	new = "<leader>an",
	select = "<leader>at",
	rename = "<leader>ar",
	delete = "<leader>aq",
	quick_question = "<leader>aq",
	modified_files = "<leader>af",
	diff = "<leader>ad",
	change_location = "<leader>al",
	new_above = "<leader>aw",
	next_window = "<S-n>",
	prev_window = "<S-l>",
}

function M.setup_global(user_keybindings)
	keybindings = vim.tbl_deep_extend("force", keybindings, user_keybindings or {})

	vim.keymap.set("n", keybindings.toggle, handlers.normal_mode, {
		desc = "Toggle Cursor Agent terminal",
		silent = true,
	})

	vim.keymap.set("v", keybindings.toggle, function()
		local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
		vim.api.nvim_feedkeys(esc, "x", false)
	end, {
		desc = "Toggle Cursor Agent terminal and send selection",
		silent = true,
	})

	vim.keymap.set("n", keybindings.new, handlers.new_terminal, {
		desc = "Create new Cursor Agent terminal",
		silent = true,
	})

	vim.keymap.set("n", keybindings.new_above, handlers.new_terminal_above, {
		desc = "Create new Cursor Agent terminal above current window",
		silent = true,
	})

	vim.keymap.set("n", keybindings.select, handlers.select_terminal, {
		desc = "Select Cursor Agent terminal",
		silent = true,
	})

	vim.keymap.set("n", keybindings.rename, handlers.rename_terminal, {
		desc = "Rename Cursor Agent terminal",
		silent = true,
	})

	vim.keymap.set("n", keybindings.delete, handlers.delete_terminal, {
		desc = "Delete Cursor Agent terminal",
		silent = true,
	})

	vim.keymap.set("n", keybindings.modified_files, handlers.modified_files, {
		desc = "Open modified files picker",
		silent = true,
	})

	vim.keymap.set("n", keybindings.diff, function()
		require("neovim-cursor.diff").open()
	end, {
		desc = "Open diff viewer for agent sessions",
		silent = true,
	})

	vim.keymap.set("n", keybindings.change_location, handlers.change_location, {
		desc = "Change working directory for agent terminals",
		silent = true,
	})

	-- vim.keymap.set("v", keybindings.quick_question, function()
	-- 	local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
	-- 	vim.api.nvim_feedkeys(esc, "x", false)
	-- 	vim.schedule(H.quick_question_handler)
	-- end, {
	-- 	desc = "Ask a quick question about visual selection",
	-- 	silent = true,
	-- })

	vim.keymap.set("n", keybindings.next_window, "<C-w>w", {
		desc = "Focus next window",
		silent = true,
	})
	vim.keymap.set("n", keybindings.prev_window, "<C-w>W", {
		desc = "Focus previous window",
		silent = true,
	})
end

return M
