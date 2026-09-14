---@class FeyHeadingPromotedEvent: FeyEvent
---@field heading FeyHeading
---@field file FeyFile
---@field old_level number
local HeadingPromotedEvent = {
  type = 'fey.heading_promoted',
}

---@param heading FeyHeading
---@param old_level number
function HeadingPromotedEvent:new(heading, old_level)
  local obj = setmetatable({}, self)
  self.__index = self
  obj.heading = heading
  obj.file = heading.file
  obj.old_level = old_level
  return obj
end

return HeadingPromotedEvent
