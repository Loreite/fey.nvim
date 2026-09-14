---@class FeyTodoChangedEvent: FeyEvent
---@field type string
---@field heading FeyHeading
---@field old_todo_state? string
---@field was_done? boolean
local TodoChangedEvent = {
  type = 'fey.todo_changed',
}

---@param heading FeyHeading
---@param old_todo_state? string
---@param was_done? boolean
function TodoChangedEvent:new(heading, old_todo_state, was_done)
  local obj = setmetatable({}, self)
  self.__index = self
  obj.heading = heading
  obj.old_todo_state = old_todo_state
  obj.was_done = was_done
  return obj
end

return TodoChangedEvent
