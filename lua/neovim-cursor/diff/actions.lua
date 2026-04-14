-- Accept / reject helpers for diff change blocks.
-- Accepting a change writes newText to disk and marks the DB row "accepted".
-- Rejecting only marks the DB row "rejected" (no file modification).

local db = require("neovim-cursor.acp.db")

local M = {}

-- Write the new_text of a change to disk and mark it accepted.
-- @param change table  A row from db.get_pending / db.get_all
--                      Must have: id, file_path, new_text
-- @return boolean  true on success
function M.accept(change)
  if not change or not change.file_path or not change.new_text then
    return false
  end

  -- Split by newline; writefile expects a list of lines (no trailing \n per element).
  local lines = vim.split(change.new_text, "\n", { plain = true })

  -- Remove a single trailing empty element produced by a trailing newline.
  if #lines > 0 and lines[#lines] == "" then
    lines[#lines] = nil
  end

  local abs_path = vim.fn.fnamemodify(change.file_path, ":p")

  -- Ensure parent directory exists.
  local parent = vim.fn.fnamemodify(abs_path, ":h")
  vim.fn.mkdir(parent, "p")

  local result = vim.fn.writefile(lines, abs_path)
  if result ~= 0 then
    vim.notify(
      string.format("[neovim-cursor] Failed to write %s", change.file_path),
      vim.log.levels.ERROR
    )
    return false
  end

  db.mark_status(change.id, "accepted")

  -- If the file is open in a buffer, reload it to reflect the change.
  vim.schedule(function()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      local buf_name = vim.api.nvim_buf_get_name(buf)
      if vim.fn.fnamemodify(buf_name, ":p") == abs_path then
        if vim.api.nvim_buf_is_loaded(buf) then
          vim.api.nvim_buf_call(buf, function()
            vim.cmd("edit!")
          end)
        end
        break
      end
    end
  end)

  return true
end

-- Mark a change as rejected (no file modification).
-- @param change table  Must have: id
-- @return boolean
function M.reject(change)
  if not change or not change.id then
    return false
  end
  db.mark_status(change.id, "rejected")
  return true
end

-- Accept all pending changes for a given file path within a project cwd.
-- @param file_path  string  The file path (as stored in the DB)
-- @param cwd        string  Project root used to scope the query
-- @return number  Count of changes accepted
function M.accept_all_in_file(file_path, cwd)
  local changes = db.get_pending(cwd)
  local count   = 0
  for _, change in ipairs(changes) do
    if change.file_path == file_path then
      if M.accept(change) then
        count = count + 1
      end
    end
  end
  return count
end

-- Reject all pending changes for a given file path within a project cwd.
-- @param file_path  string
-- @param cwd        string
-- @return number  Count of changes rejected
function M.reject_all_in_file(file_path, cwd)
  local changes = db.get_pending(cwd)
  local count   = 0
  for _, change in ipairs(changes) do
    if change.file_path == file_path then
      if M.reject(change) then
        count = count + 1
      end
    end
  end
  return count
end

return M
