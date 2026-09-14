local FeyAgendaTagsType = require('fey.agenda.types.tags')

---@class FeyAgendaTagsTodoType:FeyAgendaTagsType
local FeyAgendaTagsTodoType = {}
FeyAgendaTagsTodoType.__index = FeyAgendaTagsTodoType

---@param opts FeyAgendaTagsTypeOpts
function FeyAgendaTagsTodoType:new(opts)
  opts.todo_only = true
  setmetatable(self, { __index = FeyAgendaTagsType })
  local obj = FeyAgendaTagsType:new(opts)
  if not obj then
    return nil
  end
  setmetatable(obj, self)
  return obj
end

return FeyAgendaTagsTodoType
