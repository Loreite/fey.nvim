---@class FeyBufferChangedEvent: FeyEvent
---@field file FeyFile
---@field list boolean?
local BufferChangedEvent = {
  type = 'fey.heading_moved',
}

---@param file FeyFile
---@param list boolean?
function BufferChangedEvent:new(file, list)
  local obj = setmetatable({}, self)
  self.__index = self
  obj.file = file
  obj.list = list
  return obj
end

return BufferChangedEvent
