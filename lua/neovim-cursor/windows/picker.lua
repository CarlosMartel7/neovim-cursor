-- Terminal picker for neovim-cursor plugin
--
-- Provides fuzzy finder UI for selecting agent terminals with:
-- - Telescope integration (preferred) with live preview of agent conversations
-- - vim.ui.select fallback for users without Telescope
-- - Rename capability directly from picker with <C-r>
-- - Automatic return to terminal insert mode after selection
--
-- Features:
-- - Live preview showing terminal buffer content
-- - Status indicators (running/stopped, age)
-- - Fuzzy search by agent name
-- - Picker automatically reopens after rename for seamless workflow
--
local tabs = require("neovim-cursor.windows.tabs")
local terminal = require("neovim-cursor.windows.terminal")

local M = {}

-- Format terminal info for display in picker
-- @param term Terminal metadata object
-- @return string Formatted display string
local function format_terminal_display(term)
  local status_icon = "?"  -- Running
  local status_text = "running"
  
  -- Check if terminal is actually running
  if not terminal.is_running(term.id) then
    status_icon = "?"  -- Stopped
    status_text = "stopped"
  end
  
  -- Calculate age
  local age_seconds = os.time() - term.created_at
  local age_str
  if age_seconds < 60 then
    age_str = age_seconds .. "s ago"
  elseif age_seconds < 3600 then
    age_str = math.floor(age_seconds / 60) .. "m ago"
  else
    age_str = math.floor(age_seconds / 3600) .. "h ago"
  end
  
  -- Format: "? Agent 1 (running, 5m ago)"
  return string.format("%s %s (%s, %s)", status_icon, term.name, status_text, age_str)
end

-- Check if Telescope is available
local function has_telescope()
  return pcall(require, "telescope")
end

local function get_file_icon(path)
  local ok, devicons = pcall(require, "nvim-web-devicons")
  if not ok or not devicons then
    return "", "Normal"
  end

  local filename = vim.fn.fnamemodify(path, ":t")
  local extension = vim.fn.fnamemodify(path, ":e")
  local icon, icon_hl = devicons.get_icon(filename, extension, { default = true })
  return icon or "", icon_hl or "Normal"
end

local function get_modified_files()
  local output = vim.fn.systemlist("git -C " .. vim.fn.shellescape(vim.fn.getcwd()) .. " status --porcelain")
  local files = {}

  for _, line in ipairs(output) do
    if line and line ~= "" then
      local status = line:sub(1, 2)
      local path = line:sub(4)
      local rename_target = path:match(".* %-%> (.+)$")
      if rename_target and rename_target ~= "" then
        path = rename_target
      end
      path = vim.trim(path)
      if path ~= "" then
        table.insert(files, {
          path = path,
          status = status,
          icon = nil,
          icon_hl = nil,
        })
        files[#files].icon, files[#files].icon_hl = get_file_icon(path)
      end
    end
  end

  return files
end

local function split_files_by_agent_origin(files)
  local ordinary = {}
  local agent = {}

  local baseline = {}
  local last_id = tabs.get_last()
  if last_id then
    baseline = terminal.get_modified_baseline(last_id) or {}
  end

  for _, item in ipairs(files) do
    if baseline[item.path] then
      table.insert(ordinary, item)
    else
      table.insert(agent, item)
    end
  end

  return ordinary, agent
end

local function pick_modified_with_telescope(ordinary, agent)
  local ok = pcall(require, "telescope")
  if not ok then
    return false
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local entry_display = require("telescope.pickers.entry_display")

  local entries = {}
  local function add_section(title, group_items)
    if #group_items == 0 then
      return
    end
    table.insert(entries, {
      is_header = true,
      title = title,
      ordinal = title,
    })
    for _, item in ipairs(group_items) do
      table.insert(entries, {
        is_header = false,
        path = item.path,
        status = item.status,
        icon = item.icon,
        icon_hl = item.icon_hl,
        ordinal = item.path,
      })
    end
  end

  add_section("Ordinary edits", ordinary)
  add_section("Agent edits", agent)

  local displayer = entry_display.create({
    separator = " ",
    items = {
      { width = 2 },
      { width = 3 },
      { remaining = true },
    },
  })

  pickers
    .new({}, {
      prompt_title = "Modified Files",
      finder = finders.new_table({
        results = entries,
        entry_maker = function(entry)
          return {
            value = entry,
            ordinal = entry.ordinal,
            path = entry.path,
            is_header = entry.is_header,
            display = function(item)
              if item.is_header then
                return item.value.title
              end
              return displayer({
                { item.value.icon, item.value.icon_hl or "Normal" },
                { item.value.status, "Comment" },
                item.value.path,
              })
            end,
          }
        end,
      }),
      sorter = conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          local selection = action_state.get_selected_entry()
          if not selection or selection.is_header or not selection.path then
            return
          end
          actions.close(prompt_bufnr)
          vim.cmd("edit " .. vim.fn.fnameescape(selection.path))
        end)
        return true
      end,
    })
    :find()

  return true
end

-- Pick terminal using Telescope (if available)
-- @param terminals Array of terminal metadata
-- @param config Configuration object
-- @param callback function(selected_id) Called with selected terminal ID
local function pick_with_telescope(terminals, config, callback)
  local ok, telescope = pcall(require, "telescope")
  if not ok then
    return false
  end
  
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local previewers = require("telescope.previewers")
  
  -- Build entries for telescope
  local entries = {}
  for _, term in ipairs(terminals) do
    table.insert(entries, {
      id = term.id,
      display = format_terminal_display(term),
      ordinal = term.name,  -- For searching/filtering
      value = term,
    })
  end

  -- Create a custom previewer for terminal buffers
  local terminal_previewer = previewers.new_buffer_previewer({
    title = "Agent Conversation",
    define_preview = function(self, entry, status)
      -- Get the terminal info
      local term_info = terminal._get_terminal(entry.id)

      if term_info and term_info.buf and vim.api.nvim_buf_is_valid(term_info.buf) then
        -- Get terminal buffer lines
        local lines = vim.api.nvim_buf_get_lines(term_info.buf, 0, -1, false)

        -- Set lines in preview buffer
        vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)

        -- Optional: Set filetype for syntax highlighting
        vim.api.nvim_buf_set_option(self.state.bufnr, 'filetype', 'terminal')
      else
        -- Terminal not running or buffer invalid
        vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, {
          "Terminal not running",
          "",
          "Status: " .. (terminal.is_running(entry.id) and "running" or "stopped")
        })
      end
    end,
  })

  pickers.new({}, {
    prompt_title = "Select Cursor Agent Terminal",
    finder = finders.new_table({
      results = entries,
      entry_maker = function(entry)
        return {
          value = entry.value,
          display = entry.display,
          ordinal = entry.ordinal,
          id = entry.id,
        }
      end,
    }),
    sorter = conf.generic_sorter({}),
    previewer = terminal_previewer,
    attach_mappings = function(prompt_bufnr, map)
      -- Default action: select terminal
      actions.select_default:replace(function()
        actions.close(prompt_bufnr)
        local selection = action_state.get_selected_entry()
        if selection then
          callback(selection.id)
          -- Enter insert mode in the terminal after switching
          vim.schedule(function()
            vim.cmd("startinsert")
          end)
        end
      end)
      
      -- Custom action: rename terminal with <C-r>
      map("i", "<C-r>", function()
        local selection = action_state.get_selected_entry()
        if selection then
          local term = selection.value
          actions.close(prompt_bufnr)
          
          -- Prompt for new name
          vim.schedule(function()
            vim.ui.input({
              prompt = "Rename agent window: ",
              default = term.name,
            }, function(input)
              if input and input ~= "" then
                if tabs.rename_terminal(selection.id, input) then
                  vim.notify("Terminal renamed to: " .. input, vim.log.levels.INFO)
                  -- Re-open picker to show updated names
                  vim.schedule(function()
                    M.pick_terminal(config, callback)
                  end)
                else
                  vim.notify("Failed to rename terminal", vim.log.levels.ERROR)
                end
              end
            end)
          end)
        end
      end)
      
      -- Also map <C-r> in normal mode for Telescope
      map("n", "<C-r>", function()
        local selection = action_state.get_selected_entry()
        if selection then
          local term = selection.value
          actions.close(prompt_bufnr)
          
          -- Prompt for new name
          vim.schedule(function()
            vim.ui.input({
              prompt = "Rename agent window: ",
              default = term.name,
            }, function(input)
              if input and input ~= "" then
                if tabs.rename_terminal(selection.id, input) then
                  vim.notify("Terminal renamed to: " .. input, vim.log.levels.INFO)
                  -- Re-open picker to show updated names
                  vim.schedule(function()
                    M.pick_terminal(config, callback)
                  end)
                else
                  vim.notify("Failed to rename terminal", vim.log.levels.ERROR)
                end
              end
            end)
          end)
        end
      end)
      
      return true
    end,
  }):find()
  
  return true
end

-- Pick terminal using vim.ui.select (fallback)
-- @param terminals Array of terminal metadata
-- @param callback function(selected_id) Called with selected terminal ID
local function pick_with_ui_select(terminals, callback)
  -- Build display items
  local items = {}
  local id_map = {}
  
  for i, term in ipairs(terminals) do
    items[i] = format_terminal_display(term)
    id_map[i] = term.id
  end
  
  vim.ui.select(items, {
    prompt = "Select Cursor Agent Terminal:",
    format_item = function(item)
      return item
    end,
  }, function(choice, idx)
    if idx then
      callback(id_map[idx])
      -- Enter insert mode in the terminal after switching
      vim.schedule(function()
        vim.cmd("startinsert")
      end)
    end
  end)
end

-- Main picker function - shows terminal selection UI
-- @param config Configuration object
-- @param callback function(selected_id) Called with selected terminal ID
function M.pick_terminal(config, callback)
  local terminals = tabs.list_terminals()
  
  -- Handle edge cases
  if #terminals == 0 then
    vim.notify("No terminals available. Create one with <leader>an", vim.log.levels.WARN)
    return
  end
  
  if #terminals == 1 then
    -- Only one terminal, auto-select it (or show picker anyway based on config)
    -- For now, let's auto-select to avoid unnecessary UI
    callback(terminals[1].id)
    return
  end
  
  -- Try Telescope first, fall back to vim.ui.select
  if has_telescope() then
    local success = pick_with_telescope(terminals, config, callback)
    if success then
      return
    end
  end
  
  -- Fallback to vim.ui.select
  pick_with_ui_select(terminals, callback)
end

-- Show a file picker limited to git-modified files.
function M.pick_modified_files()
  local files = get_modified_files()
  if #files == 0 then
    vim.notify("No modified files in current git workspace", vim.log.levels.INFO)
    return
  end

  local ordinary, agent = split_files_by_agent_origin(files)

  if pick_modified_with_telescope(ordinary, agent) then
    return
  end

  local display_items = {}
  local index_map = {}

  local function add_section(title, entries)
    if #entries == 0 then
      return
    end
    table.insert(display_items, string.format("---- %s ----", title))
    table.insert(index_map, nil)
    for _, item in ipairs(entries) do
      table.insert(display_items, string.format("%s  %s  %s", item.icon, item.status, item.path))
      table.insert(index_map, item.path)
    end
  end

  add_section("Ordinary edits", ordinary)
  add_section("Agent edits", agent)

  vim.ui.select(display_items, {
    prompt = "Modified files:",
    format_item = function(item)
      return item
    end,
  }, function(_, idx)
    local path = idx and index_map[idx] or nil
    if path and path ~= "" then
      vim.cmd("edit " .. vim.fn.fnameescape(path))
    end
  end)
end

require("neovim-cursor.log").debug("picker", "loaded")

return M
