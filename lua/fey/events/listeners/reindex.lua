---@param event FeyTodoChangedEvent | FeyHeadingDemotedEvent | FeyHeadingPromotedEvent
return function(event)
  event.heading:reindex_buffer()
end
