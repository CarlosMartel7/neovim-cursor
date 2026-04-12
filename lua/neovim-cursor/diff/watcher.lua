-- Watches ~/.cursor/projects/<hash>/worker.log for indexing events.
--
-- When the Cursor agent modifies files, the background worker re-indexes
-- them and appends "Indexing finished" to worker.log.  On that signal
-- the watcher re-reads the most recent agent-transcript JSONL to detect
-- new edits and adds them to diff.state.

local log = require("neovim-cursor.log")
local parser = require("neovim-cursor.diff.parser")
local diff_state = require("neovim-cursor.diff.state")

local M = {}

local watcher = {
	handle = nil,
	worker_log_path = nil,
	last_log_offset = 0,
	last_jsonl_offset = 0,
	last_jsonl_path = nil,
	project_cwd = nil,
	active = false,
}

--- Find the most recently modified agent-transcript JSONL for the project.
local function find_latest_transcript()
	local sessions = parser.list_sessions(watcher.project_cwd)
	if #sessions == 0 then
		return nil
	end
	return sessions[1]
end

--- Read new lines from the active transcript since our last offset and
--- parse any new turns (user→assistant→edits) from them.
local function scan_transcript_for_new_edits()
	local session = find_latest_transcript()
	if not session then
		return
	end

	local jsonl_path = session.path

	-- If the transcript changed (new session started), reset our offset.
	if jsonl_path ~= watcher.last_jsonl_path then
		watcher.last_jsonl_path = jsonl_path
		watcher.last_jsonl_offset = 0
		diff_state.reset()
		diff_state.set_session_id(session.id)
	end

	local f = io.open(jsonl_path, "r")
	if not f then
		return
	end

	f:seek("set", watcher.last_jsonl_offset)
	local new_data = f:read("*a")
	local new_offset = f:seek()
	f:close()

	if not new_data or new_data == "" then
		return
	end
	watcher.last_jsonl_offset = new_offset

	-- Accumulate assistant messages and flush on each user message or EOF.
	local current_prompt = nil
	local current_edits = {}

	local function flush_turn()
		if #current_edits > 0 then
			diff_state.add_turn(current_edits, current_prompt)
			local sum = diff_state.summary()
			vim.notify(
				string.format(
					"Agent turn %d: %d new edit(s) (%d pending total)",
					sum.turns,
					#current_edits,
					sum.pending
				),
				vim.log.levels.INFO
			)
		end
		current_prompt = nil
		current_edits = {}
	end

	for line in new_data:gmatch("[^\n]+") do
		local ok, obj = pcall(vim.json.decode, line)
		if not ok or not obj then
			goto continue
		end

		local role = obj.role or obj.type
		local content = obj.message and obj.message.content

		if role == "user" then
			flush_turn()
			if type(content) == "table" then
				for _, block in ipairs(content) do
					if block.type == "text" and type(block.text) == "string" then
						local text = block.text:match("<user_query>%s*(.-)%s*</user_query>") or block.text
						current_prompt = vim.trim(text):sub(1, 120)
						break
					end
				end
			end
		elseif role == "assistant" then
			if type(content) == "table" then
				for _, block in ipairs(content) do
					if block.type == "tool_use" then
						parser._process_tool_use(block, current_edits)
					end
				end
			end
		end

		::continue::
	end
	flush_turn()
end

--- Called when worker.log changes.  Reads new lines looking for
--- "Indexing finished" — the signal that files were just updated.
local function on_worker_log_changed()
	local path = watcher.worker_log_path
	if not path then
		return
	end

	local f = io.open(path, "r")
	if not f then
		return
	end

	local size = f:seek("end")

	-- File was truncated / rotated — reset.
	if size < watcher.last_log_offset then
		watcher.last_log_offset = 0
	end

	f:seek("set", watcher.last_log_offset)
	local new_data = f:read("*a")
	f:close()

	if not new_data or new_data == "" then
		return
	end
	watcher.last_log_offset = size

	if new_data:match("%[info%] Indexing finished") then
		scan_transcript_for_new_edits()
	end
end

--- Start watching worker.log for the given project directory.
--- @param project_cwd string  absolute project path (used to derive hash)
function M.start(project_cwd)
	M.stop()

	local home = vim.fn.expand("~")
	local hash = parser.project_hash(project_cwd)
	local worker_log = home .. "/.cursor/projects/" .. hash .. "/worker.log"

	watcher.project_cwd = project_cwd
	watcher.worker_log_path = worker_log
	watcher.last_log_offset = 0
	watcher.last_jsonl_offset = 0
	watcher.last_jsonl_path = nil
	watcher.active = true

	-- Skip existing worker.log content so we only react to new events.
	local f = io.open(worker_log, "r")
	if f then
		watcher.last_log_offset = f:seek("end")
		f:close()
	end

	-- Also skip existing transcript content.
	local session = find_latest_transcript()
	if session then
		watcher.last_jsonl_path = session.path
		diff_state.set_session_id(session.id)
		local jf = io.open(session.path, "r")
		if jf then
			watcher.last_jsonl_offset = jf:seek("end")
			jf:close()
		end
	end

	local handle = vim.loop.new_fs_event()
	if not handle then
		log.debug("diff.watcher", "failed to create fs_event")
		return false
	end

	watcher.handle = handle
	handle:start(worker_log, {}, function(err, _, _)
		if err then
			log.debug("diff.watcher", "fs_event error: " .. tostring(err))
			return
		end
		vim.schedule(function()
			on_worker_log_changed()
		end)
	end)

	log.debug("diff.watcher", "started watching " .. worker_log)
	return true
end

function M.stop()
	if watcher.handle then
		watcher.handle:stop()
		watcher.handle:close()
		watcher.handle = nil
	end
	watcher.active = false
	watcher.worker_log_path = nil
	watcher.project_cwd = nil
	watcher.last_log_offset = 0
	watcher.last_jsonl_offset = 0
	watcher.last_jsonl_path = nil
	log.debug("diff.watcher", "stopped")
end

function M.is_active()
	return watcher.active
end

function M.get_path()
	return watcher.worker_log_path
end

log.debug("diff.watcher", "loaded")

return M
