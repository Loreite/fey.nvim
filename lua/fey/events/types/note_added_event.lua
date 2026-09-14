---@class FeyNoteAddedEvent: FeyEvent
---@field type string
---@field heading FeyHeading
---@field note string[]
local NoteAddedEvent = {
  type = 'fey.note_added',
}

---@param heading FeyHeading
---@param note string[]
function NoteAddedEvent:new(heading, note)
  local obj = setmetatable({}, self)
  self.__index = self
  obj.heading = heading
  obj.note = note
  return obj
end

return NoteAddedEvent
