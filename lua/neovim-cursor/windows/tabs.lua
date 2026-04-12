-- Multi-terminal state management for neovim-cursor plugin
--
-- This module manages the metadata for multiple agent terminals, providing:
-- - Terminal creation and deletion
-- - Active/last terminal tracking for smart toggling
-- - Terminal renaming and listing
-- - Automatic cleanup via callbacks from terminal.lua
--
-- Architecture:
-- - This module stores metadata (id, name, timestamps) only
-- - The actual terminal buffers/windows are managed by terminal.lua
-- - Cleanup callbacks ensure state stays synchronized when terminals exit
--
local terminal = require("neovim-cursor.windows.terminal")

local M = {}

-- State: Centralized storage for all terminal metadata
local state = {
	terminals = {}, -- Table of terminal metadata keyed by ID
	active_id = nil, -- Currently active terminal ID (shown in window)
	last_id = nil, -- Last active terminal ID (used for smart toggle with <leader>ai)
	counter = 0, -- Counter for generating unique IDs (increments for each new terminal)
	agent_cwd = nil, -- Shared working directory for all agent terminals (nil = vim cwd)
}

-- Register cleanup callback to sync when terminals exit
terminal.register_cleanup_callback(function(id, exit_code)
	-- Clean up terminal metadata when terminal exits
	if state.terminals[id] then
		state.terminals[id] = nil

		-- Update active_id if this was the active terminal
		if state.active_id == id then
			state.active_id = nil
		end

		-- Update last_id to the most recently active terminal
		if state.last_id == id then
			local list = M.list_terminals()
			if #list > 0 then
				state.last_id = list[1].id
			else
				state.last_id = nil
			end
		end
	end
end)

-- Generate a unique terminal ID
local function generate_id()
	state.counter = state.counter + 1
	return "term-" .. state.counter
end

-- Generate a terminal name
local function generate_name(config)
	local prefix = "Agent"
	if config and config.terminal and config.terminal.default_name then
		prefix = config.terminal.default_name
	end

	return prefix .. " " .. state.counter
end

-- Create a new terminal
-- @param name (optional) Custom name for the terminal
-- @param config Configuration object
-- @return terminal_id The ID of the created terminal
function M.create_terminal(name, config)
	local id = generate_id()

	-- Generate name if not provided
	if not name or name == "" then
		name = generate_name(config)
	end

	-- Store terminal metadata
	state.terminals[id] = {
		id = id,
		name = name,
		created_at = os.time(),
		last_active = os.time(),
	}

	-- Spawn the process in the agent cwd if one is set.
	local agent_dir = state.agent_cwd or vim.fn.getcwd()
	local saved_cwd = vim.fn.getcwd()
	if state.agent_cwd then
		vim.fn.chdir(state.agent_cwd)
	end

	-- Create the actual terminal instance
	terminal._create_terminal_instance(id, config)

	if state.agent_cwd then
		vim.fn.chdir(saved_cwd)
	end

	-- Set as active and last terminal
	state.active_id = id
	state.last_id = id
	terminal._set_active(id)

	-- Auto-start the diff watcher on worker.log for this project.
	local ok_diff, diff_mod = pcall(require, "neovim-cursor.diff")
	if ok_diff and diff_mod and diff_mod.start_watching then
		diff_mod.start_watching(agent_dir)
	end

	return id
end

-- Get terminal metadata by ID
-- @param id Terminal ID
-- @return terminal metadata table or nil
function M.get_terminal(id)
	return state.terminals[id]
end

-- List all terminals
-- @return table Array of terminal metadata
function M.list_terminals()
	local list = {}
	for _, term in pairs(state.terminals) do
		table.insert(list, term)
	end

	-- Sort by creation time (newest first)
	table.sort(list, function(a, b)
		return a.created_at > b.created_at
	end)

	return list
end

-- Get the active terminal ID
-- @return string|nil Active terminal ID
function M.get_active()
	return state.active_id
end

-- Switch to a specific terminal
-- @param id Terminal ID to switch to
-- @param config Configuration object
-- @return boolean Success
function M.switch_to(id, config)
	if not state.terminals[id] then
		vim.notify("Terminal " .. id .. " does not exist", vim.log.levels.ERROR)
		return false
	end

	-- Hide current terminal if visible (unless multiple agent windows can stay open)
	local multi = config and config.terminal and config.terminal.multiple_windows
	if not multi and state.active_id and state.active_id ~= id then
		terminal.hide(state.active_id)
	end

	-- Update active terminal
	state.active_id = id
	state.last_id = id
	state.terminals[id].last_active = os.time()
	terminal._set_active(id)

	-- Show the new terminal
	if terminal.is_running(id) then
		terminal.toggle(config, id) -- This will show it if hidden
	else
		-- Terminal died, recreate it
		terminal._create_terminal_instance(id, config)
	end

	return true
end

-- Get the last active terminal ID
-- @return string|nil Last terminal ID
function M.get_last()
	return state.last_id
end

-- Delete/close a terminal
-- @param id Terminal ID to delete
-- @return boolean Success
function M.delete_terminal(id)
	if not state.terminals[id] then
		return false
	end

	terminal.delete(id)

	-- Remove from metadata
	state.terminals[id] = nil

	-- Update active/last IDs if needed
	if state.active_id == id then
		state.active_id = nil
	end

	if state.last_id == id then
		-- Set last_id to the most recently active terminal
		local list = M.list_terminals()
		if #list > 0 then
			state.last_id = list[1].id
		else
			state.last_id = nil
		end
	end

	return true
end

-- Rename a terminal
-- @param id Terminal ID
-- @param new_name New name for the terminal
-- @return boolean Success
function M.rename_terminal(id, new_name)
	if not state.terminals[id] then
		return false
	end

	if not new_name or new_name == "" then
		vim.notify("Terminal name cannot be empty", vim.log.levels.WARN)
		return false
	end

	state.terminals[id].name = new_name
	return true
end

-- Check if any terminals exist
-- @return boolean
function M.has_terminals()
	return next(state.terminals) ~= nil
end

-- Get count of terminals
-- @return number
function M.count()
	local count = 0
	for _ in pairs(state.terminals) do
		count = count + 1
	end
	return count
end

-- Get state (for debugging)
function M.get_state()
	return {
		terminals = state.terminals,
		active_id = state.active_id,
		last_id = state.last_id,
		counter = state.counter,
		count = M.count(),
		agent_cwd = state.agent_cwd,
	}
end

-- Get current agent cwd (falls back to vim cwd if not overridden).
function M.get_agent_cwd()
	return state.agent_cwd or vim.fn.getcwd()
end

-- Set a new agent cwd. Validates the path, then restarts all running terminals in it.
-- @param new_path string Absolute or relative path to switch to
-- @param config table Plugin config
-- @return boolean, string  success, error_message
function M.change_location(new_path, config)
	local expanded = vim.fn.fnamemodify(new_path, ":p")
	-- Strip trailing slash for consistency
	expanded = expanded:gsub("[/\\]$", "")

	if vim.fn.isdirectory(expanded) == 0 then
		return false, "Not a valid directory: " .. expanded
	end

	state.agent_cwd = expanded

	-- Restart every running terminal in the new location.
	local saved_cwd = vim.fn.getcwd()
	vim.fn.chdir(expanded)

	local list = M.list_terminals()
	for _, term_meta in ipairs(list) do
		terminal.delete(term_meta.id)
		state.terminals[term_meta.id] = nil
	end
	state.active_id = nil
	state.last_id = nil

	if #list > 0 then
		for _, term_meta in ipairs(list) do
			M.create_terminal(term_meta.name, config)
		end
	end

	vim.fn.chdir(saved_cwd)
	return true, nil
end

require("neovim-cursor.log").debug("tabs", "loaded")

return M
