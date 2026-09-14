---@class FeyClockedOutEvent: FeyEvent
---@field heading? FeyHeading
local ClockedOutEvent = {
  type = 'fey.clocked_out',
}
ClockedOutEvent.__index = ClockedOutEvent

---@param heading FeyHeading
function ClockedOutEvent:new(heading)
  return setmetatable({
    heading = heading,
  }, self)
end

return ClockedOutEvent
