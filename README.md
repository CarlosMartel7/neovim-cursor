# neovim-cursor

**BIG DISCLAIMER**: This is not a _real_ plugin in the `neovim` sense of a plugin. It's just a way to integrate `cursor-cli` into the `neovim` editor. So whenever you read that it's a "plugin" , just read it as "terminal integration" (or something like that).

A Neovim plugin to integrate the Cursor AI agent CLI directly into your editor. Toggle a terminal running `cursor agent`
with a simple keybinding and send visual selections for AI assistance.

This was created using cursor 😊 in 20 minutes, it doesn't have to be perfect, just need something to run cursor agent like the agent inside cursor.


## Features

- 🚀 Toggle a vertical split terminal running `cursor agent` with `<leader>ai`
- 🎛️ **Manage multiple AI agent sessions simultaneously**
- 🔍 **Fuzzy finder with live preview** (Telescope integration)
- ✏️ **Rename and organize** agent terminals for different tasks
- ⌨️ **Full terminal mode support** - manage agents without leaving the terminal
- 📝 Send visual selections and file paths to the Cursor agent
- 💾 Persistent terminal sessions (hide/show without restarting)
- ⚙️ Fully configurable (keybindings, split position, separator, multiple visible splits, line numbers, etc.)
- 🎯 Written in pure Lua


## Requirements

- Neovim >= 0.8.0
- `cursor` CLI installed and available in your PATH


## Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "felixcuello/neovim-cursor",
  config = function()
    require("neovim-cursor").setup()
  end,
}
```

### Using [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  "felixcuello/neovim-cursor",
  config = function()
    require("neovim-cursor").setup()
  end,
}
```

### Using [vim-plug](https://github.com/junegunn/vim-plug)

```vim
Plug 'felixcuello/neovim-cursor'

lua << EOF
require("neovim-cursor").setup()
EOF
```

## Usage

### Quick Start

1. **Open/Toggle Agent**: Press `<leader>ai` in normal mode
   - First time: Creates your first agent terminal
   - After that: Toggles (show/hide) the last active agent
2. **Create New Agent**: Press `<leader>an` to create additional agent terminals
3. **Switch Agents**: Press `<leader>at` to open a fuzzy picker with live preview
4. **Rename Agent**: Press `<leader>ar` to rename the current agent terminal

### Multi-Terminal Management

Work with multiple AI agents simultaneously for different tasks:

#### From Normal Mode

| Keybinding | Action |
|------------|--------|
| `<leader>ai` | Smart toggle - create first agent or show last active |
| `<leader>an` | Create new agent terminal with custom prompt |
| `<leader>at` | Select agent from fuzzy picker (with live preview) |
| `<leader>ar` | Rename current agent terminal |
| `<leader>aq` | Delete current agent terminal |
| `<S-n>` / `<S-l>` | Focus next / previous window |

#### From Terminal Mode

When you're inside an agent terminal, you can manage agents without leaving:

| Keybinding | Action |
|------------|--------|
| `<Esc>` | Exit terminal mode (Normal mode in buffer; use `<leader>` maps, then e.g. toggle to hide) |
| `<S-n>` / `<S-l>` | Focus next / previous window (from terminal mode) |
| `<C-n>` | Create new agent terminal |
| `<C-t>` | Select agent from fuzzy picker |
| `<C-r>` | Rename current agent terminal |

#### Example Workflow

```
1. Press <leader>ai → Creates "Agent 1"
2. Ask: "Help me debug this authentication issue"
3. Press <C-n> → Prompt appears
4. Type: "Review my database schema"
5. Now you have two agents running!
6. Press <C-t> → Telescope shows both with live preview
7. Navigate and press Enter to switch
8. Press <C-r> → Rename to "Auth Debug" and "Schema Review"
```

### Visual Mode

Send code selections to your active agent:

1. Select text in visual mode (v, V, or Ctrl-v)
2. Press `<leader>ai`
3. The plugin will:
   - Toggle the agent terminal (show it)
   - Send the file path with line range (e.g., `@file.lua:10-20`)

Example:
```
@/path/to/your/file.lua:10-15
```

The agent will have context about which file and lines you're referring to.

### Commands

The plugin provides comprehensive commands for all operations:

#### Terminal Management
- `:CursorAgent` - Toggle agent terminal (smart toggle)
- `:CursorAgentNew [prompt]` - Create new agent terminal with optional initial prompt
- `:CursorAgentSelect` - Open agent picker
- `:CursorAgentRename [name]` - Rename active agent (interactive if no argument)
- `:CursorAgentList` - List all agent terminals with status
- `:CursorAgentDelete` - Delete active agent terminal

> **Note:** To close an agent terminal, simply type `exit` in the terminal or press `Ctrl+D`

#### Utilities
- `:CursorAgentSend <text>` - Send arbitrary text to active agent
- `:CursorAgentVersion` - Display plugin version

## Configuration

### Default Configuration

```lua
require("neovim-cursor").setup({
  -- Multi-terminal keybindings (all configurable)
  keybindings = {
    toggle = "<leader>ai",      -- Toggle agent window (show last active)
    new = "<leader>an",          -- Create new agent terminal
    select = "<leader>at",       -- Select agent terminal (fuzzy picker)
    rename = "<leader>ar",       -- Rename current agent terminal
    delete = "<leader>aq",       -- Delete current agent terminal
    next_window = "<S-n>",       -- Focus next split window (Normal mode; also in agent terminal)
    prev_window = "<S-l>",       -- Focus previous split window
  },

  -- Terminal naming and behavior
  terminal = {
    default_name = "Agent",      -- Default name prefix for terminals
    auto_number = true,          -- Auto-append numbers (Agent 1, Agent 2, etc.)
    hide_line_numbers = true,    -- Hide number/relativenumber in agent windows (false = inherit global)
    multiple_windows = false,    -- If true, keep other agent splits visible when switching/creating
  },

  -- Terminal split configuration
  split = {
    position = "right",  -- "right", "left", "top", "bottom"
    size = 0.5,          -- 50% of editor width/height (0.0-1.0)
    separator = true,    -- Draw a visible split line between editor and agent (see separator_highlight)
    separator_highlight = { fg = "#ffffff" },  -- :help nvim_set_hl() fields for WinSeparator highlight
  },

  -- CLI command to run
  command = "cursor agent",

  -- Terminal callbacks (optional)
  term_opts = {
    on_open = function()
      -- Called when terminal opens
      print("Cursor agent started")
    end,
    on_close = function(exit_code)
      -- Called when terminal closes
      print("Cursor agent exited with code: " .. exit_code)
    end,
  },
})
```

### Custom Configuration Examples

#### Custom Keybindings

```lua
require("neovim-cursor").setup({
  keybindings = {
    toggle = "<C-a>",       -- Use Ctrl+a for toggle
    new = "<C-n>",          -- Use Ctrl+n for new terminal
    select = "<C-s>",       -- Use Ctrl+s for select
    rename = "<leader>rn",  -- Use <leader>rn for rename
    delete = "<leader>rq",  -- Use <leader>rq for delete
    next_window = "<S-n>",  -- optional overrides
    prev_window = "<S-l>",
  },
})
```

#### Custom Terminal Names

```lua
require("neovim-cursor").setup({
  terminal = {
    default_name = "AI Assistant",  -- Custom prefix
    auto_number = true,              -- "AI Assistant 1", "AI Assistant 2", etc.
  },
})
```

#### Left Split with 40% Width

```lua
require("neovim-cursor").setup({
  split = {
    position = "left",
    size = 0.4,
  },
})
```

#### Multiple visible agent splits

When `terminal.multiple_windows` is `true`, switching agents or creating a new one from terminal mode does **not** hide other agent windows, so you can keep several splits open at once. When `false` (default), only one agent split is visible at a time (previous one is hidden).

```lua
require("neovim-cursor").setup({
  terminal = {
    multiple_windows = true,
  },
})
```

#### Line numbers in the agent window

By default the plugin turns off `number` and `relativenumber` in agent windows. Set `hide_line_numbers = false` to use your global editor settings there.

```lua
require("neovim-cursor").setup({
  terminal = {
    hide_line_numbers = false,
  },
})
```

#### Split separator (vertical line)

A highlighted `WinSeparator` is applied on the agent split so the boundary is easy to see. Disable it or change the color:

```lua
require("neovim-cursor").setup({
  split = {
    separator = true,
    separator_highlight = { fg = "#ffffff" },
  },
})
```

#### Custom Command with Arguments

```lua
require("neovim-cursor").setup({
  command = "cursor agent --model gpt-4",
})
```

#### Backward Compatibility

The old `keybinding` option is still supported for backward compatibility:

```lua
require("neovim-cursor").setup({
  keybinding = "<leader>ai",  -- Still works, sets the toggle keybinding
})
```

## Advanced Usage

### Programmatic Access

You can access the terminal functions directly:

```lua
local cursor = require("neovim-cursor")

-- Access plugin version
print("Version: " .. cursor.version)

-- Toggle terminal
cursor.normal_mode_handler()

-- Create new terminal programmatically
cursor.new_terminal_handler()

-- Send text to active terminal
cursor.terminal.send_text("@myfile.lua\nExplain this code")

-- Check if terminal is running
local terminal_id = cursor.tabs.get_active()
if cursor.terminal.is_running(terminal_id) then
  print("Terminal is running")
end

-- List all terminals
local terminals = cursor.tabs.list_terminals()
for _, term in ipairs(terminals) do
  print(string.format("%s: %s", term.id, term.name))
end

-- Get terminal state (for debugging)
local state = cursor.tabs.get_state()
print(vim.inspect(state))
```

### Multi-Terminal API

```lua
local tabs = require("neovim-cursor.windows.tabs")

-- Get active terminal ID
local active_id = tabs.get_active()

-- Get terminal metadata
local term = tabs.get_terminal(active_id)
print("Name: " .. term.name)
print("Created: " .. term.created_at)

-- Rename a terminal
tabs.rename_terminal(active_id, "New Name")

-- Delete a terminal
tabs.delete_terminal(active_id)

-- Check if any terminals exist
if tabs.has_terminals() then
  print("Terminals count: " .. tabs.count())
end
```

## Tips & Best Practices

### Organizing Your Agents

Use descriptive names to organize agents by task:
- **"Backend API"** - for backend code questions
- **"Frontend UI"** - for UI/UX implementation
- **"Debug Session"** - for troubleshooting
- **"Code Review"** - for reviewing pull requests
- **"Documentation"** - for writing docs

### Efficient Workflows

1. **Keep agents focused**: Create separate agents for different contexts instead of mixing topics in one
2. **Use terminal mode shortcuts**: Stay in terminal mode with `<C-n>`, `<C-t>`, `<C-r>` for faster navigation
3. **Leverage the preview**: Use `<C-t>` to preview conversations before switching
4. **Name early**: Rename agents as soon as you know their purpose with `<C-r>`

### Telescope Integration

For the best experience, install [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim). The picker will:
- Show live preview of agent conversations
- Support fuzzy searching by agent name
- Allow renaming directly from the picker with `<C-r>`

Without Telescope, the plugin falls back to `vim.ui.select` (still functional, just less features).

## Troubleshooting

### Terminal doesn't open

- Ensure the `cursor` CLI is installed and in your PATH
- Try running `cursor agent` manually in your terminal to verify it works
- Check for errors with `:messages`

### Keybinding doesn't work

- Make sure `<leader>` is set in your config (e.g., `vim.g.mapleader = " "`)
- Check for conflicting keybindings with `:verbose map <leader>ai`

### Visual selection not working

- Ensure you're pressing `<leader>ai` while still in visual mode
- The selection will be sent after the terminal opens/shows

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## Related Projects

- [Cursor](https://cursor.sh/) - The AI-first code editor
- [toggleterm.nvim](https://github.com/akinsho/toggleterm.nvim) - Terminal management for Neovim
- [vim-floaterm](https://github.com/voldikss/vim-floaterm) - Floating terminal plugin
