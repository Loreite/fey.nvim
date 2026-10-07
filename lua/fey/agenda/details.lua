-- The lines of an agenda that say where its items come from, so the title and the item lines stay clean:
-- a `Scope:` line under the title (`fey_agenda_show_scope`) and, under an item, its hollow and file
-- (`fey_agenda_show_hollow`: `auto` is when the agenda reads more than one hollow).
local config = require('fey.config')
local utils = require('fey.utils')
local AgendaLine = require('fey.agenda.view.line')
local AgendaLineToken = require('fey.agenda.view.token')

local M = {}

---@param source? FeyAgendaSource
---@return FeyAgendaLine|nil
function M.scope_line(source)
  if config.fey_agenda_show_scope == false or not source then return nil end
  return AgendaLine:single_token({
    content = 'Scope: ' .. source:describe(),
    hl_group = '@fey.agenda.hollow',
  })
end

---Whether items get a line saying which hollow they are in
---@param source? FeyAgendaSource
---@return boolean
function M.show_hollow(source)
  local mode = config.fey_agenda_show_hollow
  if mode == false or mode == 'never' or not source then return false end
  if mode == true or mode == 'always' then return true end
  return #source:hollows() > 1
end

---The line under an item with its hollow and file. It belongs to the same heading as the item, so the
---actions work on either.
---@param entry FeyAgendaEntry
---@param metadata table must have `category_length`; the rest is copied
---@return FeyAgendaLine
function M.hollow_line(entry, metadata)
  local line = AgendaLine:new({
    hl_group = '@fey.agenda.hollow',
    heading = entry,
    metadata = vim.tbl_extend('force', metadata, { detail = true }),
  })
  line:add_token(AgendaLineToken:new({
    content = '  '
      .. utils.pad_right('', metadata.category_length or 0)
      .. ('%s · %s'):format(entry.hollow or '', entry.path or ''),
  }))
  return line
end

return M
