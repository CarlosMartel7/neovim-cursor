-- Two-panel diff viewer for pending ACP changes.
--
-- Layout (opened with :CursorDiff):
--
--   ┌─────────────────────────┬──────────────────────────────────────┐
--   │  Changes (left panel)   │  Diff preview (right panel)          │
--   │  Turn 1  "prompt text"  │  --- a/src/foo.lua                   │
--   │   ▸ src/foo.lua [pend]  │  +++ b/src/foo.lua                   │
--   │   ▸ src/bar.lua [pend]  │  @@ -1,3 +1,4 @@                    │
--   │  Turn 2  "next prompt"  │   line 1                             │
--   │   ▸ src/main.lua [acc]  │  +new line                           │
--   └─────────────────────────┴──────────────────────────────────────┘
--
-- Keymaps (left panel):
--   ga   accept change under cursor
--   gr   reject change under cursor
--   gA   accept all pending changes in the file under cursor
--   gR   reject all pending changes in the file under cursor
--   q    close viewer

local db      = require("neovim-cursor.acp.db")
local actions = require("neovim-cursor.diff.actions")

local M = {}

-- ---------------------------------------------------------------------------
-- State (one viewer at a time)
-- ---------------------------------------------------------------------------

local state = {
  left_buf    = nil,
  right_buf   = nil,
  left_win    = nil,
  right_win   = nil,
  -- Ordered list of display items.  Each item is either:
  --   { kind = "header", turn, prompt }   (turn group heading)
  --   { kind = "change", change }         (a change row)
  items       = {},
  -- Maps left-panel line number (1-based) → item index in state.items
  line_to_item = {},
  cwd         = nil,
}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local STATUS_LABEL = {
  pending  = "[pending]",
  accepted = "[accepted]",
  rejected = "[rejected]",
}

local function short_path(path, cwd)
  if cwd and path:sub(1, #cwd) == cwd then
    local rel = path:sub(#cwd + 1)
    -- strip leading slash
    return rel:gsub("^[/\\]", "")
  end
  return vim.fn.fnamemodify(path, ":.")
end

-- Build the lines + line→item map from the current DB state.
local function build_display(cwd)
  local rows = db.get_all(cwd)

  -- Group rows by turn_number
  local turns = {}
  local turn_order = {}
  for _, row in ipairs(rows) do
    local t = row.turn_number or 0
    if not turns[t] then
      turns[t] = { prompt = row.prompt_text or "", changes = {} }
      table.insert(turn_order, t)
    end
    table.insert(turns[t].changes, row)
  end
  table.sort(turn_order)

  local items       = {}
  local lines       = {}
  local line_to_item = {}

  for _, t in ipairs(turn_order) do
    local grp    = turns[t]
    local prompt = grp.prompt ~= "" and ('"' .. grp.prompt .. '"') or "(no prompt)"
    local header = string.format("Turn %d  %s", t, prompt)
    table.insert(items, { kind = "header", turn = t, prompt = grp.prompt })
    table.insert(lines, header)
    line_to_item[#lines] = #items

    for _, change in ipairs(grp.changes) do
      local label = string.format(
        "  ▸ %-50s %s",
        short_path(change.file_path, cwd),
        STATUS_LABEL[change.status] or ""
      )
      table.insert(items, { kind = "change", change = change })
      table.insert(lines, label)
      line_to_item[#lines] = #items
    end

    -- Blank separator between turns
    table.insert(items, { kind = "sep" })
    table.insert(lines, "")
    -- sep line maps to nothing meaningful
  end

  return lines, items, line_to_item
end

-- Render the right panel with the unified diff for a change.
local function render_diff(change)
  if not (state.right_buf and vim.api.nvim_buf_is_valid(state.right_buf)) then
    return
  end

  if not change then
    vim.api.nvim_buf_set_lines(state.right_buf, 0, -1, false, { "-- no change selected --" })
    return
  end

  local old = change.old_text or ""
  local new = change.new_text or ""

  local diff_text = vim.diff(old, new, {
    result_type = "unified",
    algorithm   = "histogram",
    ctxlen      = 5,
  }) or ""

  local diff_lines = vim.split(diff_text, "\n", { plain = true })

  -- Prepend file header lines that vim.diff omits
  local header = {
    "--- a/" .. (change.file_path or ""),
    "+++ b/" .. (change.file_path or ""),
  }
  -- Only add them if vim.diff didn't produce its own
  if #diff_lines == 0 or not diff_lines[1]:match("^---") then
    for i, h in ipairs(header) do
      table.insert(diff_lines, i, h)
    end
  end

  vim.bo[state.right_buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.right_buf, 0, -1, false, diff_lines)
  vim.bo[state.right_buf].modifiable = false
end

-- Re-render the left panel from the DB and rebuild the internal maps.
local function refresh(keep_cursor)
  if not (state.left_buf and vim.api.nvim_buf_is_valid(state.left_buf)) then
    return
  end

  local cursor_line = 1
  if keep_cursor and state.left_win and vim.api.nvim_win_is_valid(state.left_win) then
    cursor_line = vim.api.nvim_win_get_cursor(state.left_win)[1]
  end

  local lines, items, line_to_item = build_display(state.cwd)
  state.items        = items
  state.line_to_item = line_to_item

  vim.bo[state.left_buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.left_buf, 0, -1, false, lines)
  vim.bo[state.left_buf].modifiable = false

  -- Restore / clamp cursor
  local max_line = math.max(1, #lines)
  cursor_line    = math.min(cursor_line, max_line)
  if state.left_win and vim.api.nvim_win_is_valid(state.left_win) then
    vim.api.nvim_win_set_cursor(state.left_win, { cursor_line, 0 })
  end
end

-- Return the change row under the cursor in the left panel, or nil.
local function change_at_cursor()
  if not (state.left_win and vim.api.nvim_win_is_valid(state.left_win)) then
    return nil
  end
  local line = vim.api.nvim_win_get_cursor(state.left_win)[1]
  local idx  = state.line_to_item[line]
  if not idx then return nil end
  local item = state.items[idx]
  if item and item.kind == "change" then
    return item.change
  end
  return nil
end

-- Close the viewer and clean up.
local function close()
  if state.left_win  and vim.api.nvim_win_is_valid(state.left_win)  then
    vim.api.nvim_win_close(state.left_win, true)
  end
  if state.right_win and vim.api.nvim_win_is_valid(state.right_win) then
    vim.api.nvim_win_close(state.right_win, true)
  end
  -- Buffers are wiped via bufhidden=wipe
  state.left_buf    = nil
  state.right_buf   = nil
  state.left_win    = nil
  state.right_win   = nil
  state.items       = {}
  state.line_to_item = {}
end

-- ---------------------------------------------------------------------------
-- Keymaps
-- ---------------------------------------------------------------------------

local function setup_keymaps(buf, cwd)
  local opts = { noremap = true, silent = true, buffer = buf }

  -- ga: accept change under cursor
  vim.keymap.set("n", "ga", function()
    local change = change_at_cursor()
    if not change then
      vim.notify("[neovim-cursor] No change under cursor", vim.log.levels.WARN)
      return
    end
    if change.status ~= "pending" then
      vim.notify("[neovim-cursor] Change is already " .. change.status, vim.log.levels.INFO)
      return
    end
    if actions.accept(change) then
      vim.notify("[neovim-cursor] Accepted: " .. change.file_path, vim.log.levels.INFO)
      refresh(true)
      render_diff(change_at_cursor())
    end
  end, opts)

  -- gr: reject change under cursor
  vim.keymap.set("n", "gr", function()
    local change = change_at_cursor()
    if not change then
      vim.notify("[neovim-cursor] No change under cursor", vim.log.levels.WARN)
      return
    end
    if change.status ~= "pending" then
      vim.notify("[neovim-cursor] Change is already " .. change.status, vim.log.levels.INFO)
      return
    end
    if actions.reject(change) then
      vim.notify("[neovim-cursor] Rejected: " .. change.file_path, vim.log.levels.INFO)
      refresh(true)
      render_diff(change_at_cursor())
    end
  end, opts)

  -- gA: accept all pending changes for the file under cursor
  vim.keymap.set("n", "gA", function()
    local change = change_at_cursor()
    if not change then
      vim.notify("[neovim-cursor] No change under cursor", vim.log.levels.WARN)
      return
    end
    local count = actions.accept_all_in_file(change.file_path, cwd)
    vim.notify(
      string.format("[neovim-cursor] Accepted %d change(s) in %s", count, change.file_path),
      vim.log.levels.INFO
    )
    refresh(true)
    render_diff(change_at_cursor())
  end, opts)

  -- gR: reject all pending changes for the file under cursor
  vim.keymap.set("n", "gR", function()
    local change = change_at_cursor()
    if not change then
      vim.notify("[neovim-cursor] No change under cursor", vim.log.levels.WARN)
      return
    end
    local count = actions.reject_all_in_file(change.file_path, cwd)
    vim.notify(
      string.format("[neovim-cursor] Rejected %d change(s) in %s", count, change.file_path),
      vim.log.levels.INFO
    )
    refresh(true)
    render_diff(change_at_cursor())
  end, opts)

  -- q: close viewer
  vim.keymap.set("n", "q", close, opts)
end

-- ---------------------------------------------------------------------------
-- Public open() function
-- ---------------------------------------------------------------------------

-- Open the two-panel diff viewer.
-- @param opts table?  { cwd?: string }  defaults to vim.fn.getcwd()
function M.open(opts)
  opts = opts or {}
  local cwd = opts.cwd
    or (vim.fn.getcwd and vim.fn.getcwd())
    or vim.loop.cwd()
  cwd = vim.fn.fnamemodify(cwd, ":p"):gsub("[/\\]$", "")

  -- If already open, just focus the left window.
  if state.left_win and vim.api.nvim_win_is_valid(state.left_win) then
    vim.api.nvim_set_current_win(state.left_win)
    return
  end

  state.cwd = cwd

  -- Create right (diff preview) buffer first, then split left.
  state.right_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.right_buf].buftype    = "nofile"
  vim.bo[state.right_buf].bufhidden  = "wipe"
  vim.bo[state.right_buf].swapfile   = false
  vim.bo[state.right_buf].filetype   = "diff"
  vim.bo[state.right_buf].modifiable = false
  vim.api.nvim_buf_set_name(state.right_buf, "CursorDiff:preview")

  -- Open a new tab so we don't disturb the editor layout.
  vim.cmd("tabnew")
  state.right_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.right_win, state.right_buf)

  -- Split left panel (40 columns wide)
  vim.cmd("leftabove vsplit")
  state.left_win = vim.api.nvim_get_current_win()

  state.left_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(state.left_win, state.left_buf)
  vim.bo[state.left_buf].buftype    = "nofile"
  vim.bo[state.left_buf].bufhidden  = "wipe"
  vim.bo[state.left_buf].swapfile   = false
  vim.bo[state.left_buf].filetype   = ""
  vim.bo[state.left_buf].modifiable = false
  vim.api.nvim_buf_set_name(state.left_buf, "CursorDiff:changes")

  -- Resize left panel
  vim.api.nvim_win_set_width(state.left_win, 60)

  -- Window-local options for the left panel
  vim.wo[state.left_win].number         = false
  vim.wo[state.left_win].relativenumber = false
  vim.wo[state.left_win].wrap           = false
  vim.wo[state.left_win].cursorline     = true
  vim.wo[state.left_win].signcolumn     = "no"

  -- Window-local options for the right panel
  vim.wo[state.right_win].number         = false
  vim.wo[state.right_win].relativenumber = false
  vim.wo[state.right_win].wrap           = false
  vim.wo[state.right_win].signcolumn     = "no"

  -- Set the tab title
  vim.api.nvim_buf_set_name(state.left_buf, "CursorDiff:changes")

  -- Populate left panel
  refresh(false)

  -- Set up keymaps
  setup_keymaps(state.left_buf, cwd)

  -- Update diff preview when cursor moves in the left panel.
  local au_group = vim.api.nvim_create_augroup("NeovimCursorDiffView", { clear = true })
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorHold" }, {
    buffer  = state.left_buf,
    group   = au_group,
    callback = function()
      render_diff(change_at_cursor())
    end,
  })

  -- Cleanup state when the buffer is wiped.
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer  = state.left_buf,
    group   = au_group,
    once    = true,
    callback = function()
      state.left_buf    = nil
      state.left_win    = nil
      state.items       = {}
      state.line_to_item = {}
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer  = state.right_buf,
    group   = au_group,
    once    = true,
    callback = function()
      state.right_buf = nil
      state.right_win = nil
    end,
  })

  -- Show diff for first item immediately.
  render_diff(change_at_cursor())

  -- Focus left panel
  vim.api.nvim_set_current_win(state.left_win)

  if #state.items == 0 then
    vim.notify("[neovim-cursor] No changes recorded for this project.", vim.log.levels.INFO)
  end
end

-- Reload the left panel contents (called after external DB updates).
function M.refresh()
  refresh(true)
  render_diff(change_at_cursor())
end

return M
