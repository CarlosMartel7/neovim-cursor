-- Default configuration for neovim-cursor plugin
local M = {}

M.defaults = {
	-- Keybinding for toggling cursor agent (backward compatibility)
	keybinding = "<leader>ai",

	-- Multi-terminal keybindings
	keybindings = {
		toggle = "<leader>ai", -- Toggle agent window (show last active)
		new = "<leader>an", -- Create new agent terminal
		select = "<leader>at", -- Select agent terminal (fuzzy picker)
		rename = "<leader>ar", -- Rename current agent terminal
		delete = "<leader>aq", -- Delete current agent terminal
		quick_question = "<leader>aq", -- Ask agent about the selection
		quick_edit = "<leader>ae", -- Runs agent to edit the selection
		next_window = "<S-n>", -- Focus next split window
		prev_window = "<S-l>", -- Focus previous split window
	},

	-- Terminal naming configuration
	terminal = {
		default_name = "Agent", -- Default name prefix for terminals
		auto_number = true, -- Auto-append numbers (Agent 1, Agent 2, etc.)
		-- When true, agent windows hide line numbers (number / relativenumber off in that window)
		hide_line_numbers = true,
		-- When true, new agents can stay visible alongside existing ones (no auto-hide on switch)
		multiple_windows = false,
	},

	-- Terminal split configuration
	split = {
		position = "right", -- right, left, top, bottom
		size = 0.5, -- 50% of editor width/height
		-- Draw a visible separator between the main editor and the agent split
		separator = true,
		-- Highlight for WinSeparator on the agent window (see :help winhighlight)
		separator_highlight = { fg = "#ffffff" },
	},

	-- CLI command to run
	command = "cursor agent",

	-- Terminal options
	term_opts = {
		on_open = nil, -- Callback when terminal opens
		on_close = nil, -- Callback when terminal closes
	},
}

-- Merge user config with defaults
-- Maintains backward compatibility with old 'keybinding' option
function M.setup(user_config)
	user_config = user_config or {}

	-- Backward compatibility: if old 'keybinding' provided but not 'keybindings', migrate it
	if user_config.keybinding and not user_config.keybindings then
		user_config.keybindings = {
			toggle = user_config.keybinding,
		}
	end

	return vim.tbl_deep_extend("force", M.defaults, user_config)
end

require("neovim-cursor.log").debug("config", "loaded")

return M
