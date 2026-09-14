---@class FeyBufferChangedEvent: FeyEvent
---@field file FeyFile
local HeadingMovedEvent = {
  type = 'fey.heading_moved',
}

---@param file FeyFile
function HeadingMovedEvent:new(file)
  local obj = setmetatable({}, self)
  self.__index = self
  obj.file = file
  return obj
end

return HeadingMovedEvent
