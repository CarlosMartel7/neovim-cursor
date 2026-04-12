-- Diff review module entry point for neovim-cursor.
--
-- Two flows:
--   1. Watcher flow: monitors ~/.cursor/projects/<hash>/worker.log for
--      "Indexing finished" events, then re-reads the agent transcript to
--      detect new edits.  :CursorDiff opens the view over that state.
--   2. Picker flow (fallback): :CursorDiff opens a Telescope session
--      picker and loads the selected session's edits into state.

local picker = require("neovim-cursor.diff.picker")
local view = require("neovim-cursor.diff.view")
local watcher = require("neovim-cursor.diff.watcher")
local diff_state = require("neovim-cursor.diff.state")
local log = require("neovim-cursor.log")

local M = {}

--- Open the diff review.
--- If the watcher has accumulated pending state, show it directly.
--- Otherwise fall back to the session picker.
function M.open()
	if #diff_state.get_turns() > 0 then
		view.open(nil)
		return
	end

	picker.pick_session(function(session)
		if session then
			view.open(session)
		end
	end)
end

--- Start watching worker.log for the given project directory.
--- @param project_cwd string absolute project path
function M.start_watching(project_cwd)
	diff_state.reset()
	watcher.start(project_cwd)
end

--- Stop the active watcher.
function M.stop_watching()
	watcher.stop()
end

function M.setup()
	vim.api.nvim_create_user_command("CursorDiff", function()
		M.open()
	end, {
		desc = "Review Cursor agent changes (diff viewer)",
	})

	vim.api.nvim_create_user_command("CursorDiffReset", function()
		diff_state.reset()
		vim.notify("Diff pending state cleared", vim.log.levels.INFO)
	end, {
		desc = "Clear accumulated diff state",
	})

	vim.api.nvim_create_user_command("CursorDiffStatus", function()
		local sum = diff_state.summary()
		local watching = watcher.is_active() and ("watching " .. watcher.get_path()) or "not watching"
		vim.notify(
			string.format(
				"Diff: %d turn(s), %d edit(s) — %d accepted, %d rejected, %d pending  [%s]",
				sum.turns,
				sum.total,
				sum.accepted,
				sum.rejected,
				sum.pending,
				watching
			),
			vim.log.levels.INFO
		)
	end, {
		desc = "Show diff watcher and pending state status",
	})
end

-- Expose submodules
M.parser = require("neovim-cursor.diff.parser")
M.picker = picker
M.view = view
M.watcher = watcher
M.state = diff_state
M.actions = require("neovim-cursor.diff.actions")

log.debug("diff", "loaded")

return M
