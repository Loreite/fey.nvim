---@param event FeyTodoChangedEvent | FeyHeadingDemotedEvent | FeyHeadingPromotedEvent
return function(event)
  event.heading:align_tags()
end
