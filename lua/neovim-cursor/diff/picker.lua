-- Telescope picker for Cursor agent transcript sessions.

local parser = require("neovim-cursor.diff.parser")
local log = require("neovim-cursor.log")

local M = {}

local function format_time(epoch)
	return os.date("%Y-%m-%d %H:%M", epoch)
end

function M.pick_session(callback)
	local tabs = require("neovim-cursor.windows.tabs")
	local cwd = tabs.get_agent_cwd()
	local sessions = parser.list_sessions(cwd)

	if #sessions == 0 then
		vim.notify("No agent sessions found for " .. cwd, vim.log.levels.WARN)
		return
	end

	local ok_telescope = pcall(require, "telescope")
	if ok_telescope then
		M._pick_telescope(sessions, cwd, callback)
	else
		M._pick_ui_select(sessions, callback)
	end
end

function M._pick_telescope(sessions, cwd, callback)
	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	local previewers = require("telescope.previewers")

	local previewer = previewers.new_buffer_previewer({
		title = "Session Edits",
		define_preview = function(self, entry)
			local edits = parser.parse_edits(entry.value.path)
			local _, file_order = parser.group_by_file(edits)
			local lines = {}
			table.insert(lines, "Session: " .. entry.value.id)
			table.insert(lines, "Prompt:  " .. entry.value.prompt)
			table.insert(lines, "Edits:   " .. #edits)
			table.insert(lines, "")
			table.insert(lines, "Files changed:")
			for _, fp in ipairs(file_order) do
				table.insert(lines, "  " .. fp)
			end
			if #file_order == 0 then
				table.insert(lines, "  (no file edits found)")
			end
			vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
		end,
	})

	pickers
		.new({}, {
			prompt_title = "Cursor Agent Sessions  [" .. vim.fn.fnamemodify(cwd, ":~") .. "]",
			finder = finders.new_table({
				results = sessions,
				entry_maker = function(session)
					local label = format_time(session.mtime) .. "  " .. session.prompt
					return {
						value = session,
						display = label,
						ordinal = label,
					}
				end,
			}),
			sorter = conf.generic_sorter({}),
			previewer = previewer,
			attach_mappings = function(prompt_bufnr)
				actions.select_default:replace(function()
					local selection = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if selection then
						callback(selection.value)
					end
				end)
				return true
			end,
		})
		:find()
end

function M._pick_ui_select(sessions, callback)
	local items = {}
	for _, s in ipairs(sessions) do
		table.insert(items, format_time(s.mtime) .. "  " .. s.prompt)
	end

	vim.ui.select(items, {
		prompt = "Select agent session:",
	}, function(_, idx)
		if idx then
			callback(sessions[idx])
		end
	end)
end

log.debug("diff.picker", "loaded")

return M
