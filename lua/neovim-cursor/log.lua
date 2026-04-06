-- Optional debug logging for neovim-cursor (set vim.g.neovim_cursor_debug = 1 to enable)
local M = {}

--- @param scope string Identifier (e.g. module or file name)
--- @param message? string Extra detail
function M.debug(scope, message)
  if not vim.g.neovim_cursor_debug then
    return
  end
  local text = "[neovim-cursor"
  if scope and scope ~= "" then
    text = text .. ":" .. scope
  end
  text = text .. "]"
  if message and message ~= "" then
    text = text .. " " .. message
  end
  vim.notify(text, vim.log.levels.DEBUG)
end

M.debug("log", "loaded")

return M
