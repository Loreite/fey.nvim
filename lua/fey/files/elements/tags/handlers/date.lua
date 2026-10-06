-- Handler of `date` tags and the planning tags `scheduled`, `deadline` and `closed` (names:
-- config.fey_date_tag_name and friends). Applying it opens the calendar on the date and writes the
-- chosen day back into the tag: the open-at-point mapping reaches it. A range changes its start and
-- keeps its end; repeater and warning delay stay as they are.
local config = require('fey.config')

local M = {}

---All tag names this handler is registered for
---@return string[]
function M.names()
  return {
    config.fey_date_tag_name,
    config.fey_scheduled_tag_name,
    config.fey_deadline_tag_name,
    config.fey_closed_tag_name,
  }
end

---@param tag FeyTag
function M.handler(tag)
  local Date = require('fey.objects.date')
  local Calendar = require('fey.objects.calendar')
  local edit = require('fey.files.elements.tags.edit')

  local dates = Date.from_tag(tag)
  local date = dates[1]
  if not date then
    return vim.notify('fey: not a date: ' .. tostring(tag.values[1]), vim.log.levels.WARN)
  end

  local bufnr, name = tag.bufnr, tag.name
  local row, col = tag.node:start()
  return Calendar.new({ date = date, title = 'Change date' }):open():next(function(new_date)
    if not new_date then return end
    -- the calendar is asynchronous: find the tag again
    local fresh = vim.api.nvim_buf_is_valid(bufnr) and edit.at(bufnr, row, col, { name = name })
    if not fresh then return vim.notify('fey: the date tag moved', vim.log.levels.WARN) end
    local value = new_date:to_string()
    if dates[2] then value = value .. '--' .. dates[2]:to_string() end
    local ok, err = edit.set_value(fresh, 1, value)
    if not ok then vim.notify('fey: ' .. tostring(err), vim.log.levels.WARN) end
  end)
end

M.handlers = {
  scope_tag = M.handler,
  line_tag = M.handler,
  block_tag = M.handler,
  pair_tag = M.handler,
}

return M
