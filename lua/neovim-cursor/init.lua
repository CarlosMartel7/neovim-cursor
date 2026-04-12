-- Main module for neovim-cursor plugin
--
-- This is the entry point for the plugin, providing:
-- - Plugin setup and configuration
-- - User-facing handlers for all operations (normal/visual mode, terminal operations)
-- - Command registration; keymaps live in keybidings/ (see Keybidings facade)
-- - Integration between config, terminal, tabs, picker, and handlers modules
--
local config_module = require("neovim-cursor.config")
local terminal = require("neovim-cursor.windows.terminal")
local tabs = require("neovim-cursor.windows.tabs")
local picker = require("neovim-cursor.windows.picker")
local Keybidings = require("neovim-cursor.keybidings")
local handlers = require("neovim-cursor.handlers")
local diff = require("neovim-cursor.diff")

local M = {}
local config = {}

M.normal_mode_handler = handlers.normal_mode
M.new_terminal_handler = handlers.new_terminal
M.new_terminal_above_handler = handlers.new_terminal_above
M.new_terminal_from_terminal_handler = handlers.new_terminal_from_terminal
M.select_terminal_handler = handlers.select_terminal
M.rename_terminal_handler = handlers.rename_terminal
M.delete_terminal_handler = handlers.delete_terminal
M.list_terminals_handler = handlers.list_terminals
M.visual_mode_handler = handlers.visual_mode
M.quick_question_handler = handlers.quick_question
M.toggle_terminal_handler = handlers.toggle_terminal
M.modified_files_handler = handlers.modified_files
M.change_location_handler = handlers.change_location

-- Plugin version (Semantic Versioning: MAJOR.MINOR.PATCH)
-- v1.0.0: Multi-terminal support with fuzzy picker, live preview, and full configurability
M.version = "1.0.0"

-- Setup function to initialize the plugin
function M.setup(user_config)
	-- Merge user config with defaults
	config = config_module.setup(user_config)

	handlers.set_context({
		config = config,
		terminal = terminal,
		tabs = tabs,
		picker = picker,
	})

	Keybidings.setup_global(config.keybindings)

	-- Create user command for toggle
	vim.api.nvim_create_user_command("CursorAgent", function()
		M.normal_mode_handler()
	end, {
		desc = "Toggle Cursor Agent terminal",
	})

	-- Create command to create new terminal
	vim.api.nvim_create_user_command("CursorAgentNew", function(opts)
		local name = opts.args and opts.args ~= "" and opts.args or nil
		tabs.create_terminal(name, config)
	end, {
		desc = "Create new Cursor Agent terminal",
		nargs = "?",
	})

	-- Create command to select terminal
	vim.api.nvim_create_user_command("CursorAgentSelect", function()
		M.select_terminal_handler()
	end, {
		desc = "Select Cursor Agent terminal",
	})

	-- Create command to rename terminal
	vim.api.nvim_create_user_command("CursorAgentRename", function(opts)
		local active_id = tabs.get_active()
		if not active_id then
			vim.notify("No active terminal to rename", vim.log.levels.WARN)
			return
		end

		if opts.args and opts.args ~= "" then
			-- Name provided as argument
			if tabs.rename_terminal(active_id, opts.args) then
				vim.notify("Terminal renamed to: " .. opts.args, vim.log.levels.INFO)
			end
		else
			-- No argument, use the interactive handler
			M.rename_terminal_handler()
		end
	end, {
		desc = "Rename Cursor Agent terminal",
		nargs = "?",
	})

	-- Create command to list terminals
	vim.api.nvim_create_user_command("CursorAgentList", function()
		M.list_terminals_handler()
	end, {
		desc = "List all Cursor Agent terminals",
	})

	-- Create command to delete active terminal
	vim.api.nvim_create_user_command("CursorAgentDelete", function()
		M.delete_terminal_handler()
	end, {
		desc = "Delete active Cursor Agent terminal",
	})

	-- Create command to send text manually
	vim.api.nvim_create_user_command("CursorAgentSend", function(opts)
		local active_id = tabs.get_active()
		if active_id and terminal.is_running(active_id) then
			terminal.send_text(opts.args, active_id)
		else
			vim.notify("Cursor agent terminal is not running", vim.log.levels.WARN)
		end
	end, {
		desc = "Send text to Cursor Agent terminal",
		nargs = "+",
	})

	-- Create command to display version
	vim.api.nvim_create_user_command("CursorAgentVersion", function()
		vim.notify("neovim-cursor v" .. M.version, vim.log.levels.INFO)
	end, {
		desc = "Display neovim-cursor plugin version",
	})

	vim.api.nvim_create_user_command("CursorAgentModifiedFiles", function()
		M.modified_files_handler()
	end, {
		desc = "Open picker for modified files",
	})

	vim.api.nvim_create_user_command("CursorAgentLocation", function(opts)
		if opts.args and opts.args ~= "" then
			local ok, err = tabs.change_location(opts.args, config)
			if ok then
				vim.notify("Agent terminals moved to: " .. vim.fn.fnamemodify(opts.args, ":p"), vim.log.levels.INFO)
			else
				vim.notify("Could not change location: " .. (err or "unknown error"), vim.log.levels.ERROR)
			end
		else
			M.change_location_handler()
		end
	end, {
		desc = "Change working directory for agent terminals",
		nargs = "?",
		complete = "dir",
	})

	diff.setup()
end

-- Expose modules for advanced usage
M.terminal = terminal
M.tabs = tabs
M.picker = picker
M.diff = diff

require("neovim-cursor.log").debug("init", "loaded")

return M
