-- Entry point for the neovim-cursor diff subsystem.
--
-- Responsibilities:
--   setup()          — initialise DB, register :CursorDiff command,
--                       schedule a startup notification if pending changes exist
--   open()           — open the two-panel diff viewer
--   start_watching() — connect the ACP client for a project directory
--                       (called by tabs.lua every time a new agent terminal starts)

local M = {}

-- Lazy-load heavy dependencies so that the module loads fast at startup.
local function get_db()      return require("neovim-cursor.acp.db")      end
local function get_client()  return require("neovim-cursor.acp.client")  end
local function get_view()    return require("neovim-cursor.diff.view")    end

-- ---------------------------------------------------------------------------
-- setup()
-- ---------------------------------------------------------------------------

function M.setup()
  local db_ok = get_db().init()
  if not db_ok then
    -- lsqlite3 not available; notify once and degrade gracefully.
    vim.schedule(function()
      vim.notify(
        "[neovim-cursor] lsqlite3 not found – diff persistence disabled.\n"
          .. "Install with: luarocks install lsqlite3",
        vim.log.levels.WARN
      )
    end)
  end

  -- Register :CursorDiff command
  if not pcall(vim.api.nvim_get_commands, {}) or true then
    vim.api.nvim_create_user_command("CursorDiff", function()
      M.open()
    end, {
      desc = "Open diff viewer for pending ACP changes",
    })
  end

  -- Register VimLeavePre to cleanly close the ACP clients and DB.
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group    = vim.api.nvim_create_augroup("NeovimCursorACP", { clear = true }),
    callback = function()
      pcall(function() get_client().disconnect_all() end)
      pcall(function() get_db().close() end)
    end,
  })

  -- Startup notification: check for pending changes on VimEnter (deferred so
  -- that the user's config is fully processed before we bother them).
  vim.api.nvim_create_autocmd("VimEnter", {
    group = vim.api.nvim_create_augroup("NeovimCursorDiffStartup", { clear = true }),
    once  = true,
    callback = function()
      vim.schedule(function()
        local cwd = vim.fn.getcwd()
        local ok, has = pcall(function() return get_db().has_pending(cwd) end)
        if ok and has then
          vim.notify(
            "[neovim-cursor] You have pending diff changes for this project.\n"
              .. "Run :CursorDiff to review them.",
            vim.log.levels.INFO
          )
        end
      end)
    end,
  })
end

-- ---------------------------------------------------------------------------
-- open()
-- ---------------------------------------------------------------------------

function M.open()
  get_view().open({ cwd = vim.fn.getcwd() })
end

-- ---------------------------------------------------------------------------
-- start_watching()
-- ---------------------------------------------------------------------------

-- Called by tabs.lua each time a new agent terminal is created.
-- Spawns (or re-uses) the ACP background process for this directory.
-- @param dir string  Absolute project directory
function M.start_watching(dir)
  if not dir or dir == "" then
    dir = vim.fn.getcwd()
  end
  dir = vim.fn.fnamemodify(dir, ":p"):gsub("[/\\]$", "")

  local client_mod = get_client()

  -- Already connected → nothing to do.
  if client_mod.is_connected(dir) then
    return
  end

  client_mod.connect(dir, {
    on_diff = function(change_row)
      -- Refresh the viewer if it's open so the new change appears immediately.
      pcall(function()
        local view = require("neovim-cursor.diff.view")
        -- Only refresh if the viewer buffers are alive.
        view.refresh()
      end)
    end,
    on_ready = function(_client)
      require("neovim-cursor.log").debug("diff", "ACP ready for " .. dir)
    end,
  })
end

return M
