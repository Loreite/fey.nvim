-- Handler of `status` tags (name: config.fey_status_tag_name): the todo keyword and the priority of a
-- heading in one tag, `{# status, TODO, A #}` (or `{# status; priority: A #}` without a keyword).
-- Applying it moves the heading to its next todo state, like the todo mapping does, or raises the priority
-- when the tag has no keyword. The open-at-point mapping reaches it.
local config = require('fey.config')

local M = {}

---@param tag FeyTag
function M.handler(tag)
  if tag.bufnr ~= vim.api.nvim_get_current_buf() then return end
  if tag.values[1] and tag.values[1] ~= '' then
    require('fey').action('fey_mappings.todo_next_state')
  else
    require('fey').action('fey_mappings.priority_up')
  end
end

M.handlers = {
  scope_tag = M.handler,
}

---@return string
function M.name() return config.fey_status_tag_name end

return M
