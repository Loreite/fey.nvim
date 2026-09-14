---@class FeyHeadingMovedEvent: FeyEvent
---@field heading FeyHeading
---@field old_level number
local HeadingMovedEvent = {
  type = 'fey.heading_moved',
}

---@param heading FeyHeading
---@param old_level number
function HeadingMovedEvent:new(heading, old_level)
  local obj = setmetatable({}, self)
  self.__index = self
  obj.heading = heading
  obj.old_level = old_level
  return obj
end

return HeadingMovedEvent
