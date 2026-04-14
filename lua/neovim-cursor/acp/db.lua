-- SQLite persistence layer for neovim-cursor ACP changes.
-- DB location: stdpath("data")/neovim-cursor/changes.db
-- Tables:
--   sessions        (id, name, cwd, created_at)
--   pending_changes (id, session_id, file_path, old_text, new_text,
--                    turn_number, prompt_text, status, created_at)

local M = {}

local db_handle = nil

local CREATE_SESSIONS = [[
CREATE TABLE IF NOT EXISTS sessions (
  id         TEXT PRIMARY KEY,
  name       TEXT NOT NULL,
  cwd        TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
]]

local CREATE_CHANGES = [[
CREATE TABLE IF NOT EXISTS pending_changes (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id   TEXT    NOT NULL,
  file_path    TEXT    NOT NULL,
  old_text     TEXT    NOT NULL,
  new_text     TEXT    NOT NULL,
  turn_number  INTEGER NOT NULL DEFAULT 0,
  prompt_text  TEXT    NOT NULL DEFAULT '',
  status       TEXT    NOT NULL DEFAULT 'pending',
  created_at   INTEGER NOT NULL,
  FOREIGN KEY (session_id) REFERENCES sessions(id)
);
]]

-- Open (or re-use) the database, creating the schema if needed.
-- Returns true on success, false + error string on failure.
function M.init()
  if db_handle then
    return true
  end

  local ok, lsqlite3 = pcall(require, "lsqlite3")
  if not ok then
    return false, "lsqlite3 not found – install it with: luarocks install lsqlite3"
  end

  local data_dir = vim.fn.stdpath("data") .. "/neovim-cursor"
  vim.fn.mkdir(data_dir, "p")
  local db_path = data_dir .. "/changes.db"

  local db, err_code, err_msg = lsqlite3.open(db_path)
  if not db then
    return false, string.format("sqlite open failed (%s): %s", tostring(err_code), tostring(err_msg))
  end

  db:exec(CREATE_SESSIONS)
  db:exec(CREATE_CHANGES)
  db_handle = db
  return true
end

-- Return the open db handle (nil if not initialised).
function M.handle()
  return db_handle
end

-- Persist a new (or upsert an existing) session row.
-- @param id      string  UUID / unique session id
-- @param name    string  Human-readable label
-- @param cwd     string  Project directory
function M.save_session(id, name, cwd)
  if not db_handle then return false end
  local stmt = db_handle:prepare([[
    INSERT OR REPLACE INTO sessions (id, name, cwd, created_at)
    VALUES (?, ?, ?, ?)
  ]])
  if not stmt then return false end
  stmt:bind_values(id, name, cwd, os.time())
  stmt:step()
  stmt:finalize()
  return true
end

-- Persist a diff change block.
-- @param t table  { session_id, file_path, old_text, new_text, turn_number, prompt_text }
-- @return inserted row id or nil
function M.save_change(t)
  if not db_handle then return nil end
  local stmt = db_handle:prepare([[
    INSERT INTO pending_changes
      (session_id, file_path, old_text, new_text, turn_number, prompt_text, status, created_at)
    VALUES (?, ?, ?, ?, ?, ?, 'pending', ?)
  ]])
  if not stmt then return nil end
  stmt:bind_values(
    t.session_id or "",
    t.file_path  or "",
    t.old_text   or "",
    t.new_text   or "",
    t.turn_number or 0,
    t.prompt_text or "",
    os.time()
  )
  stmt:step()
  stmt:finalize()
  return db_handle:last_insert_rowid()
end

-- Return all pending changes whose session belongs to the given cwd.
-- @param cwd string  Project root (matches sessions.cwd exactly)
-- @return list of row tables
function M.get_pending(cwd)
  if not db_handle then return {} end
  local rows = {}
  local sql = [[
    SELECT pc.id, pc.session_id, pc.file_path, pc.old_text, pc.new_text,
           pc.turn_number, pc.prompt_text, pc.status, pc.created_at
    FROM   pending_changes pc
    JOIN   sessions s ON s.id = pc.session_id
    WHERE  s.cwd = ? AND pc.status = 'pending'
    ORDER  BY pc.turn_number ASC, pc.id ASC
  ]]
  local stmt = db_handle:prepare(sql)
  if not stmt then return {} end
  stmt:bind_values(cwd)
  for row in stmt:nrows() do
    table.insert(rows, row)
  end
  stmt:finalize()
  return rows
end

-- Return all changes (any status) for a cwd, grouped for the viewer.
-- @param cwd string
-- @return list of row tables
function M.get_all(cwd)
  if not db_handle then return {} end
  local rows = {}
  local sql = [[
    SELECT pc.id, pc.session_id, pc.file_path, pc.old_text, pc.new_text,
           pc.turn_number, pc.prompt_text, pc.status, pc.created_at,
           s.name AS session_name
    FROM   pending_changes pc
    JOIN   sessions s ON s.id = pc.session_id
    WHERE  s.cwd = ?
    ORDER  BY pc.turn_number ASC, pc.id ASC
  ]]
  local stmt = db_handle:prepare(sql)
  if not stmt then return {} end
  stmt:bind_values(cwd)
  for row in stmt:nrows() do
    table.insert(rows, row)
  end
  stmt:finalize()
  return rows
end

-- Update the status of a single change.
-- @param id     integer  Row id in pending_changes
-- @param status string   "pending" | "accepted" | "rejected"
function M.mark_status(id, status)
  if not db_handle then return false end
  local stmt = db_handle:prepare("UPDATE pending_changes SET status = ? WHERE id = ?")
  if not stmt then return false end
  stmt:bind_values(status, id)
  stmt:step()
  stmt:finalize()
  return true
end

-- Returns true if there are any pending changes for the given cwd.
function M.has_pending(cwd)
  if not db_handle then
    -- Try a lightweight init just to answer the question.
    local ok = M.init()
    if not ok then return false end
  end
  if not db_handle then return false end
  local sql = [[
    SELECT COUNT(*) AS n
    FROM   pending_changes pc
    JOIN   sessions s ON s.id = pc.session_id
    WHERE  s.cwd = ? AND pc.status = 'pending'
  ]]
  local stmt = db_handle:prepare(sql)
  if not stmt then return false end
  stmt:bind_values(cwd)
  local count = 0
  for row in stmt:nrows() do
    count = row.n or 0
  end
  stmt:finalize()
  return count > 0
end

-- Close the database connection (call on VimLeavePre if desired).
function M.close()
  if db_handle then
    db_handle:close()
    db_handle = nil
  end
end

return M
