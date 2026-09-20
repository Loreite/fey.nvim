---@param event FeyBufferChangedEvent
return function(event)
  if event.list then
    event.file:reindex_list()
  else
    event.file:reindex_headings()
  end
end
