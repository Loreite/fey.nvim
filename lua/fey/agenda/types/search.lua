---@diagnostic disable: inject-field
local FeyAgendaTodosType = require('fey.agenda.types.todo')
local Input = require('fey.ui.input')

---@class FeyAgendaSearchTypeOpts:FeyAgendaTodosTypeOpts
---@field heading_query? string

---@class FeyAgendaSearchType:FeyAgendaTodosType
---@field heading_query? string
local FeyAgendaSearchType = {}
FeyAgendaSearchType.__index = FeyAgendaSearchType

---@param opts FeyAgendaSearchTypeOpts
function FeyAgendaSearchType:new(opts)
  opts.todo_only = false
  opts.subheader = 'Press "r" to update search'
  setmetatable(self, { __index = FeyAgendaTodosType })
  local obj = FeyAgendaTodosType:new(opts)
  setmetatable(obj, self)
  obj.heading_query = self.heading_query
  return obj
end

function FeyAgendaSearchType:prepare()
  if not self.heading_query or self.heading_query == '' then
    return self:get_search_term()
  end
end

function FeyAgendaSearchType:get_file_headings(file)
  return file:find_headings_matching_search_term(self.heading_query or '', false, true)
end

function FeyAgendaSearchType:get_search_term()
  return Input.open('Enter search term: ', self.heading_query or ''):next(function(value)
    if not value then
      return false
    end
    self.heading_query = value
    return self
  end)
end

function FeyAgendaSearchType:redraw()
  -- Skip prompt for custom views
  if self.id then
    return self
  end
  return self:get_search_term()
end

return FeyAgendaSearchType
