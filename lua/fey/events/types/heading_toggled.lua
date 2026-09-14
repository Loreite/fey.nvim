---@class FeyHeadingToggledEvent: FeyEvent
---@field heading? FeyHeading
---@field line? number
---@field action 'line_to_heading' | 'heading_to_line' | 'line_to_child_heading'
local HeadingToggledEvent = {
  type = 'fey.heading_toggled',
}
HeadingToggledEvent.__index = HeadingToggledEvent

---@param line number
---@param action 'line_to_heading' | 'heading_to_line' | 'line_to_child_heading'
---@param heading? FeyHeading
function HeadingToggledEvent:new(line, action, heading)
  return setmetatable({
    line = line,
    heading = heading,
    action = action,
  }, self)
end

return HeadingToggledEvent
