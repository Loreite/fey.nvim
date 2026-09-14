---@class FeyHeadingDemotedEvent: FeyEvent
---@field type string
---@field heading FeyHeading
---@field file FeyFile
---@field old_level number
local HeadingDemotedEvent = {
  type = 'fey.heading_demoted',
}

---@param heading FeyHeading
---@param old_level number
function HeadingDemotedEvent:new(heading, old_level)
  local obj = setmetatable({}, self)
  self.__index = self
  obj.heading = heading
  obj.file = heading.file
  obj.old_level = old_level
  return obj
end

return HeadingDemotedEvent
