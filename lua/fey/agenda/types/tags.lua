---@diagnostic disable: inject-field
local Date = require('fey.objects.date')
local config = require('fey.config')
local utils = require('fey.utils')
local Search = require('fey.files.elements.search')
local FeyAgendaTodosType = require('fey.agenda.types.todo')
local Input = require('fey.ui.input')

---@alias FeyAgendaTodoIgnoreDeadlinesTypes 'all' | 'near' | 'far' | 'past' | 'future'
---@alias FeyAgendaTodoIgnoreScheduledTypes 'all' | 'past' | 'future'

---@class FeyAgendaTagsTypeOpts:FeyAgendaTodosTypeOpts
---@field match_query? string
---@field todo_ignore_deadlines FeyAgendaTodoIgnoreDeadlinesTypes
---@field todo_ignore_scheduled FeyAgendaTodoIgnoreScheduledTypes

---@class FeyAgendaTagsType:FeyAgendaTodosType
---@field match_query string
---@field todo_ignore_deadlines FeyAgendaTodoIgnoreDeadlinesTypes
---@field todo_ignore_scheduled FeyAgendaTodoIgnoreScheduledTypes
local FeyAgendaTagsType = {}
FeyAgendaTagsType.__index = FeyAgendaTagsType

---@param opts FeyAgendaTagsTypeOpts
function FeyAgendaTagsType:new(opts)
  opts.todo_only = opts.todo_only or false
  opts.sorting_strategy = opts.sorting_strategy or vim.tbl_get(config.fey_agenda_sorting_strategy, 'tags') or {}
  if not opts.id then
    opts.subheader = 'Press "r" to update search'
  end
  setmetatable(self, { __index = FeyAgendaTodosType })
  local obj = FeyAgendaTodosType:new(opts)
  setmetatable(obj, self)
  obj.match_query = opts.match_query or ''
  obj.todo_ignore_deadlines = opts.todo_ignore_deadlines
  obj.todo_ignore_scheduled = opts.todo_ignore_scheduled
  return obj
end

function FeyAgendaTagsType:_get_header()
  if self.header then
    return self.header
  end

  return 'Headings with TAGS match: ' .. (self.match_query or '')
end

function FeyAgendaTagsType:prepare()
  if self.id or self.match_query and self.match_query ~= '' then
    return self
  end

  return self:get_tags()
end

function FeyAgendaTagsType:get_file_headings(file)
  -- Cache search object to avoid re-parsing same query for every file
  -- Re-create if query changed (e.g., user refreshed with new search)
  if not self._cached_search or self._cached_search.term ~= self.match_query then
    self._cached_search = Search:new(self.match_query)
  end
  local headings = file:apply_search(self._cached_search, self.todo_only)
  if self.todo_ignore_deadlines then
    headings = vim.tbl_filter(function(heading) ---@cast heading FeyHeading
      local deadline_date = heading:get_deadline_date()
      if not deadline_date then
        return true
      end
      if self.todo_ignore_deadlines == 'all' then
        return false
      end
      if self.todo_ignore_deadlines == 'near' then
        local diff = deadline_date:diff(Date.now(), 'day')
        return diff > config.fey_deadline_warning_days
      end
      if self.todo_ignore_deadlines == 'far' then
        local diff = deadline_date:diff(Date.now(), 'day')
        return diff <= config.fey_deadline_warning_days
      end
      if self.todo_ignore_deadlines == 'past' then
        return not deadline_date:is_same_or_before(Date.today(), 'day')
      end
      if self.todo_ignore_deadlines == 'future' then
        return not deadline_date:is_after(Date.today(), 'day')
      end
      return true
    end, headings)
  end
  if self.todo_ignore_scheduled then
    headings = vim.tbl_filter(function(heading) ---@cast heading FeyHeading
      local scheduled_date = heading:get_scheduled_date()
      if not scheduled_date then
        return true
      end
      if self.todo_ignore_scheduled == 'all' then
        return false
      end
      if self.todo_ignore_scheduled == 'past' then
        return scheduled_date:is_same_or_before(Date.today(), 'day')
      end
      if self.todo_ignore_scheduled == 'future' then
        return scheduled_date:is_after(Date.today(), 'day')
      end
      return true
    end, headings)
  end
  return headings
end

function FeyAgendaTagsType:get_tags()
  return Input.open('Match: ', self.match_query or '', function(arg_lead)
    return utils.prompt_autocomplete(arg_lead, self.files:get_tags())
  end):next(function(tags)
    if not tags then
      return false
    end
    if vim.trim(tags) == '' then
      utils.echo_warning('Invalid tag.')
      return false
    end
    self.match_query = tags
    return self
  end)
end

function FeyAgendaTagsType:redraw()
  -- Skip prompt for custom views
  if self.id then
    return self
  end
  return self:get_tags()
end

return FeyAgendaTagsType
