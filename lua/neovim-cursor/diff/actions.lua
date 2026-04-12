-- Accept/reject logic for individual file edits from Cursor agent sessions.

local log = require("neovim-cursor.log")

local M = {}

-- Apply a single StrReplace edit to a file on disk.
function M.apply_str_replace(edit)
	local path = edit.path
	local f = io.open(path, "r")
	if not f then
		vim.notify("Cannot read " .. path, vim.log.levels.ERROR)
		return false
	end
	local content = f:read("*a")
	f:close()

	local start_idx, end_idx = content:find(edit.old_string, 1, true)
	if not start_idx then
		vim.notify("old_string not found in " .. path .. ", change may already be applied", vim.log.levels.WARN)
		return false
	end

	local new_content = content:sub(1, start_idx - 1) .. edit.new_string .. content:sub(end_idx + 1)

	local fw = io.open(path, "w")
	if not fw then
		vim.notify("Cannot write " .. path, vim.log.levels.ERROR)
		return false
	end
	fw:write(new_content)
	fw:close()

	log.debug("diff.actions", "applied str_replace to " .. path)
	return true
end

-- Apply a Write edit (full file overwrite).
function M.apply_write(edit)
	local dir = vim.fn.fnamemodify(edit.path, ":h")
	vim.fn.mkdir(dir, "p")

	local fw = io.open(edit.path, "w")
	if not fw then
		vim.notify("Cannot write " .. edit.path, vim.log.levels.ERROR)
		return false
	end
	fw:write(edit.content)
	fw:close()

	log.debug("diff.actions", "applied write to " .. edit.path)
	return true
end

-- Revert a single StrReplace edit (swap old/new).
function M.revert_str_replace(edit)
	local path = edit.path
	local f = io.open(path, "r")
	if not f then
		vim.notify("Cannot read " .. path, vim.log.levels.ERROR)
		return false
	end
	local content = f:read("*a")
	f:close()

	local start_idx, end_idx = content:find(edit.new_string, 1, true)
	if not start_idx then
		vim.notify("new_string not found in " .. path .. ", change may not be applied", vim.log.levels.WARN)
		return false
	end

	local reverted = content:sub(1, start_idx - 1) .. edit.old_string .. content:sub(end_idx + 1)

	local fw = io.open(path, "w")
	if not fw then
		vim.notify("Cannot write " .. path, vim.log.levels.ERROR)
		return false
	end
	fw:write(reverted)
	fw:close()

	log.debug("diff.actions", "reverted str_replace in " .. path)
	return true
end

-- Accept an edit: for str_replace edits the change should already be on disk
-- (the agent applied it), so this is a no-op marking.  For write edits same.
function M.accept(edit)
	log.debug("diff.actions", "accepted edit on " .. edit.path)
	return true
end

-- Reject an edit: undo it on disk.
function M.reject(edit)
	if edit.type == "str_replace" then
		return M.revert_str_replace(edit)
	elseif edit.type == "write" then
		vim.notify("Cannot auto-revert a full Write; restore from git", vim.log.levels.WARN)
		return false
	elseif edit.type == "apply_patch" then
		vim.notify("Cannot auto-revert an ApplyPatch; restore from git", vim.log.levels.WARN)
		return false
	end
	return false
end

-- Build a unified diff string between two text blocks.
function M.compute_diff(old_text, new_text)
	if not old_text then
		old_text = ""
	end
	if not new_text then
		new_text = ""
	end
	if not old_text:match("\n$") then
		old_text = old_text .. "\n"
	end
	if not new_text:match("\n$") then
		new_text = new_text .. "\n"
	end
	local result = vim.diff(old_text, new_text, {
		result_type = "unified",
		ctxlen = 3,
	})
	return result or ""
end

log.debug("diff.actions", "loaded")

return M
