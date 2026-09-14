---@param event FeyTodoChangedEvent
return function(event)
  if event.heading:is_done() and not event.was_done and (event.old_todo_state and event.old_todo_state ~= '') then
    event.heading:clock_out()
  end
end
