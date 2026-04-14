-- ACP (Agent Communication Protocol) client for neovim-cursor.
--
-- Spawns `cursor-agent --acp` as a background process via vim.uv.spawn,
-- performs the JSON-RPC handshake (initialize → session/new), and streams
-- session/update notifications from stdout.  When a diff content block
-- arrives ({ type="diff", path, oldText, newText }) it is persisted to the
-- SQLite DB and forwarded to registered callbacks.
--
-- One client instance is kept per project directory (cwd); subsequent calls
-- to connect() for the same cwd reuse the existing connection.

local db = require("neovim-cursor.acp.db")
local log = require("neovim-cursor.log")

local M = {}

-- Active clients keyed by normalised cwd.
local clients = {}

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

local function new_client(cwd)
  return {
    cwd             = cwd,
    handle          = nil,   -- uv process handle
    stdin           = nil,   -- uv pipe (write)
    stdout          = nil,   -- uv pipe (read)
    stderr          = nil,   -- uv pipe (read)
    next_id         = 1,
    pending         = {},    -- id -> { resolve fn }
    on_diff_cbs     = {},    -- list of fn(change_row)
    buf             = "",    -- partial stdout accumulation
    session_id      = nil,
    turn_number     = 0,
    current_prompt  = "",
    connected       = false,
  }
end

-- Encode a JSON-RPC 2.0 request and append a newline.
local function encode_request(id, method, params)
  return vim.fn.json_encode({
    jsonrpc = "2.0",
    id      = id,
    method  = method,
    params  = params or vim.empty_dict(),
  }) .. "\n"
end

-- Encode a JSON-RPC 2.0 notification (no id).
local function encode_notification(method, params)
  return vim.fn.json_encode({
    jsonrpc = "2.0",
    method  = method,
    params  = params or vim.empty_dict(),
  }) .. "\n"
end

-- Write a raw string to the process stdin.
local function write_stdin(client, data)
  if not client.stdin then return end
  client.stdin:write(data)
end

-- Send a JSON-RPC request; returns the assigned request id.
-- on_response(result, error) will be called when the response arrives.
local function send_request(client, method, params, on_response)
  local id = client.next_id
  client.next_id = client.next_id + 1
  if on_response then
    client.pending[id] = on_response
  end
  write_stdin(client, encode_request(id, method, params))
  log.debug("acp", "→ " .. method .. " (id=" .. id .. ")")
  return id
end

-- ---------------------------------------------------------------------------
-- Notification / diff processing
-- ---------------------------------------------------------------------------

local function fire_diff_callbacks(client, change_row)
  for _, cb in ipairs(client.on_diff_cbs) do
    local ok, err = pcall(cb, change_row)
    if not ok then
      log.debug("acp", "on_diff callback error: " .. tostring(err))
    end
  end
end

local function process_content_blocks(client, blocks, session_id)
  if type(blocks) ~= "table" then return end
  for _, block in ipairs(blocks) do
    if type(block) == "table" and block.type == "diff" then
      local file_path    = block.path    or ""
      local old_text     = block.oldText or ""
      local new_text     = block.newText or ""

      local row_id = db.save_change({
        session_id  = session_id or client.session_id or "",
        file_path   = file_path,
        old_text    = old_text,
        new_text    = new_text,
        turn_number = client.turn_number,
        prompt_text = client.current_prompt,
      })

      local change_row = {
        id          = row_id,
        session_id  = session_id or client.session_id or "",
        file_path   = file_path,
        old_text    = old_text,
        new_text    = new_text,
        turn_number = client.turn_number,
        prompt_text = client.current_prompt,
        status      = "pending",
      }

      log.debug("acp", "diff block saved: " .. file_path)
      fire_diff_callbacks(client, change_row)
    end
  end
end

local function handle_notification(client, method, params)
  log.debug("acp", "← notification: " .. tostring(method))
  if method == "session/update" then
    -- params may be { session_id, content: [...] } or similar
    local session_id = (params and params.session_id) or client.session_id
    local content    = params and params.content
    process_content_blocks(client, content, session_id)
  end
end

local function handle_response(client, id, result, err)
  local cb = client.pending[id]
  client.pending[id] = nil
  if cb then
    local ok, call_err = pcall(cb, result, err)
    if not ok then
      log.debug("acp", "response callback error: " .. tostring(call_err))
    end
  end
end

-- Parse every complete newline-delimited JSON line from the buffer.
local function drain_buffer(client)
  while true do
    local nl = client.buf:find("\n")
    if not nl then break end
    local line = client.buf:sub(1, nl - 1)
    client.buf  = client.buf:sub(nl + 1)
    if vim.trim(line) ~= "" then
      local ok, msg = pcall(vim.fn.json_decode, line)
      if ok and type(msg) == "table" then
        if msg.id and msg.result ~= nil then
          -- Success response
          vim.schedule(function()
            handle_response(client, msg.id, msg.result, nil)
          end)
        elseif msg.id and msg.error ~= nil then
          -- Error response
          vim.schedule(function()
            handle_response(client, msg.id, nil, msg.error)
          end)
        elseif msg.method then
          -- Notification (no id) or request from server
          vim.schedule(function()
            handle_notification(client, msg.method, msg.params)
          end)
        end
      else
        log.debug("acp", "stdout parse error on line: " .. line)
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Handshake
-- ---------------------------------------------------------------------------

local function do_handshake(client, on_ready)
  -- Step 1: initialize
  send_request(client, "initialize", {
    protocolVersion = "2024-11-05",
    capabilities    = {},
    clientInfo      = { name = "neovim-cursor", version = "1.0.0" },
  }, function(result, err)
    if err then
      log.debug("acp", "initialize error: " .. vim.inspect(err))
      return
    end
    log.debug("acp", "initialize ok")

    -- Step 2: session/new
    send_request(client, "session/new", {
      cwd = client.cwd,
    }, function(res2, err2)
      if err2 then
        log.debug("acp", "session/new error: " .. vim.inspect(err2))
        return
      end

      local sid = (res2 and res2.session_id) or (res2 and res2.id) or ("session-" .. tostring(os.time()))
      client.session_id = sid
      client.connected  = true
      log.debug("acp", "session created: " .. sid)

      db.save_session(sid, "ACP " .. vim.fn.fnamemodify(client.cwd, ":t"), client.cwd)

      if on_ready then
        vim.schedule(function() on_ready(client) end)
      end
    end)
  end)
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Connect to cursor-agent for the given project directory.
-- If a connection already exists for that cwd, returns it immediately.
--
-- @param cwd      string   Project root
-- @param opts     table?   { on_diff?: fn(change_row), on_ready?: fn(client),
--                            command?: string, args?: string[] }
-- @return client table
function M.connect(cwd, opts)
  cwd  = vim.fn.fnamemodify(cwd or vim.fn.getcwd(), ":p"):gsub("[/\\]$", "")
  opts = opts or {}

  if clients[cwd] and clients[cwd].connected then
    -- Register extra callback if provided.
    if opts.on_diff then
      table.insert(clients[cwd].on_diff_cbs, opts.on_diff)
    end
    if opts.on_ready then
      vim.schedule(function() opts.on_ready(clients[cwd]) end)
    end
    return clients[cwd]
  end

  local client = new_client(cwd)
  clients[cwd] = client

  if opts.on_diff then
    table.insert(client.on_diff_cbs, opts.on_diff)
  end

  -- Build pipes
  client.stdin  = vim.uv.new_pipe(false)
  client.stdout = vim.uv.new_pipe(false)
  client.stderr = vim.uv.new_pipe(false)

  local cmd  = opts.command or "cursor-agent"
  local args = opts.args    or { "--acp" }

  log.debug("acp", "spawning " .. cmd .. " " .. table.concat(args, " ") .. " in " .. cwd)

  local handle, pid_or_err = vim.uv.spawn(cmd, {
    args  = args,
    stdio = { client.stdin, client.stdout, client.stderr },
    cwd   = cwd,
  }, function(code, signal)
    log.debug("acp", "process exited code=" .. code .. " signal=" .. signal)
    client.connected = false
    client.handle    = nil
    -- Remove from registry so a future connect() will respawn.
    clients[cwd] = nil
  end)

  if not handle then
    log.debug("acp", "spawn failed: " .. tostring(pid_or_err))
    -- Clean up pipes
    client.stdin:close()
    client.stdout:close()
    client.stderr:close()
    clients[cwd] = nil
    return nil
  end

  client.handle = handle
  log.debug("acp", "pid=" .. tostring(pid_or_err))

  -- Read stdout
  vim.uv.read_start(client.stdout, function(err_msg, data)
    if err_msg then
      log.debug("acp", "stdout read error: " .. tostring(err_msg))
      return
    end
    if data then
      client.buf = client.buf .. data
      drain_buffer(client)
    end
  end)

  -- Drain stderr for debugging
  vim.uv.read_start(client.stderr, function(err_msg, data)
    if data then
      log.debug("acp", "stderr: " .. vim.trim(data))
    end
  end)

  -- Initialise DB, then start handshake
  db.init()
  do_handshake(client, opts.on_ready)

  return client
end

-- Get the active client for a cwd (nil if not connected).
function M.get(cwd)
  cwd = vim.fn.fnamemodify(cwd or vim.fn.getcwd(), ":p"):gsub("[/\\]$", "")
  return clients[cwd]
end

-- Send a prompt to the agent for the given cwd.
-- @param cwd    string  Project root
-- @param text   string  User message
-- @param opts   table?  { on_response?: fn(result, err) }
function M.send_prompt(cwd, text, opts)
  cwd  = vim.fn.fnamemodify(cwd or vim.fn.getcwd(), ":p"):gsub("[/\\]$", "")
  opts = opts or {}
  local client = clients[cwd]
  if not client or not client.connected then
    log.debug("acp", "send_prompt: not connected for " .. cwd)
    return false
  end

  client.turn_number    = client.turn_number + 1
  client.current_prompt = text

  send_request(client, "session/prompt", {
    session_id = client.session_id,
    message    = text,
  }, opts.on_response)

  return true
end

-- Register a callback to be called every time a diff block is captured.
-- @param cwd  string
-- @param fn   function(change_row)
function M.on_diff(cwd, fn)
  cwd = vim.fn.fnamemodify(cwd or vim.fn.getcwd(), ":p"):gsub("[/\\]$", "")
  local client = clients[cwd]
  if client then
    table.insert(client.on_diff_cbs, fn)
  end
end

-- Gracefully disconnect the client for a cwd.
function M.disconnect(cwd)
  cwd = vim.fn.fnamemodify(cwd or vim.fn.getcwd(), ":p"):gsub("[/\\]$", "")
  local client = clients[cwd]
  if not client then return end
  if client.handle then
    -- Send notifications/exit before closing
    pcall(function()
      write_stdin(client, encode_notification("shutdown", {}))
    end)
    pcall(function() client.stdin:close() end)
    pcall(function() client.stdout:close() end)
    pcall(function() client.stderr:close() end)
    pcall(function() client.handle:kill("sigterm") end)
  end
  clients[cwd] = nil
end

-- Disconnect all active clients (e.g., on VimLeavePre).
function M.disconnect_all()
  for cwd in pairs(clients) do
    M.disconnect(cwd)
  end
end

-- Returns true if a connected client exists for the given cwd.
function M.is_connected(cwd)
  cwd = vim.fn.fnamemodify(cwd or vim.fn.getcwd(), ":p"):gsub("[/\\]$", "")
  local client = clients[cwd]
  return client ~= nil and client.connected == true
end

return M
