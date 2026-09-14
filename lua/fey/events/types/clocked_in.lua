---@class FeyClockedInEvent: FeyEvent
---@field heading? FeyHeading
local ClockedInEvent = {
  type = 'fey.clocked_in',
}
ClockedInEvent.__index = ClockedInEvent

---@param heading FeyHeading
function ClockedInEvent:new(heading)
  return setmetatable({
    heading = heading,
  }, self)
end

return ClockedInEvent
