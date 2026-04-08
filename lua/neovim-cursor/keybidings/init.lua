-- Facade for neovim-cursor keymaps (require("neovim-cursor.keybidings")).

local leader = require("neovim-cursor.keybidings.leader")
local buffer = require("neovim-cursor.keybidings.buffer")

---@class Keybidings
local Keybidings = {}

Keybidings.setup_global = leader.setup_global
Keybidings.setup_agent_terminal_buffer = buffer.setup_agent_terminal_buffer
Keybidings.setup_quick_question_float = buffer.setup_quick_question_float

-- Submodules for direct access if needed
Keybidings.leader = leader
Keybidings.buffer = buffer

return Keybidings
