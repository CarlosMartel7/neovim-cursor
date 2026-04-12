-- Persistent pending state for diff review across agent turns.
--
-- Accumulates edits from each agent turn and tracks per-edit
-- accept/reject status.  State lives for the Neovim session only.

local log = require("neovim-cursor.log")

local M = {}

local state = {
	session_id = nil,
	turns = {},
	edit_status = {},
	listeners = {},
}

function M.reset()
	state.session_id = nil
	state.turns = {}
	state.edit_status = {}
	M._notify()
end

--- Append a completed agent turn.
--- @param edits table[] list of edit records from parser
--- @param prompt string|nil user prompt that triggered this turn
--- @return table|nil the turn record, or nil if edits was empty
function M.add_turn(edits, prompt)
	if #edits == 0 then
		return nil
	end
	local turn_num = #state.turns + 1
	local turn = {
		turn_num = turn_num,
		prompt = prompt or "(no prompt)",
		timestamp = os.time(),
		edits = edits,
	}
	table.insert(state.turns, turn)
	log.debug("diff.state", "added turn " .. turn_num .. " with " .. #edits .. " edits")
	M._notify()
	return turn
end

function M.set_session_id(id)
	state.session_id = id
end

function M.get_session_id()
	return state.session_id
end

function M.get_turns()
	return state.turns
end

function M.get_status(edit)
	return state.edit_status[edit]
end

function M.set_status(edit, status)
	state.edit_status[edit] = status
	M._notify()
end

function M.has_pending()
	for _, turn in ipairs(state.turns) do
		for _, edit in ipairs(turn.edits) do
			if not state.edit_status[edit] then
				return true
			end
		end
	end
	return false
end

--- All edits across turns grouped by file path.
--- Each entry carries a reference to its parent turn and current status.
function M.all_edits_by_file()
	local by_file = {}
	local order = {}
	for _, turn in ipairs(state.turns) do
		for _, edit in ipairs(turn.edits) do
			if not by_file[edit.path] then
				by_file[edit.path] = {}
				table.insert(order, edit.path)
			end
			table.insert(by_file[edit.path], {
				edit = edit,
				turn = turn,
				status = state.edit_status[edit],
			})
		end
	end
	return by_file, order
end

--- Register a listener that fires whenever state changes.
function M.on_change(callback)
	table.insert(state.listeners, callback)
end

function M._notify()
	for _, cb in ipairs(state.listeners) do
		pcall(cb)
	end
end

function M.summary()
	local total = 0
	local accepted = 0
	local rejected = 0
	for _, turn in ipairs(state.turns) do
		for _, edit in ipairs(turn.edits) do
			total = total + 1
			local s = state.edit_status[edit]
			if s == "accepted" then
				accepted = accepted + 1
			elseif s == "rejected" then
				rejected = rejected + 1
			end
		end
	end
	return {
		turns = #state.turns,
		total = total,
		accepted = accepted,
		rejected = rejected,
		pending = total - accepted - rejected,
	}
end

log.debug("diff.state", "loaded")

return M
