---@param event FeyTodoChangedEvent | FeyHeadingDemotedEvent | FeyHeadingPromotedEvent
return function(event)
  event.file:reindex_headings()
end
