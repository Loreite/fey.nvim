local Date = require('fey.objects.date')
local fey = require('fey')

---@class FeyApiAgenda
local FeyAgenda = {}

---@alias FeyApiAgendaFilter string see Filters to apply to the current view. See `:help fey-fey_agenda_filter` for more information

local function get_date(date, name)
  if not date then
    return nil
  end
  if Date.is_date_instance(date) then
    return date
  end
  if type(date) == 'string' then
    return Date.from_string(date)
  end

  error(('Invalid format for "%s" date in Fey Agenda'):format(name), 0)
end

local function get_shared_opts(options)
  options = options or {}
  local opts = {}
  if options.filters and options.filters ~= '' then
    opts.filter = options.filters
  end
  opts.header = options.header
  opts.paths = options.fey_agenda_files
  opts.scope = options.scope
  opts.sorting_strategy = options.fey_agenda_sorting_strategy
  opts.tag_filter = options.fey_agenda_tag_filter_preset
  opts.category_filter = options.fey_agenda_category_filter_preset
  opts.remove_labels = options.fey_agenda_remove_labels
  return opts
end

local function get_match_opts(options)
  local opts = get_shared_opts(options)
  opts.match_query = options.match_query
  opts.todo_ignore_scheduled = options.fey_agenda_todo_ignore_scheduled
  opts.todo_ignore_deadlines = options.fey_agenda_todo_ignore_deadlines
  return opts
end

---@class FeyApiAgendaOpts
---@field filters? FeyApiAgendaFilter
---@field header? string
---@field scope? FeyScopeSpec Hollows the view reads: 'current', 'tree', 'court' or a list of references. Default: `fey_agenda_scope`
---@field fey_agenda_files? string[] Limit the view to these files and directories (globs work)
---@field fey_agenda_tag_filter_preset? string
---@field fey_agenda_category_filter_preset? string
---@field fey_agenda_sorting_strategy? FeyAgendaSortingStrategy[]
---@field fey_agenda_remove_labels? boolean

---@class FeyApiAgendaOptions:FeyApiAgendaOpts
---@field from? string | FeyDate
---@field span? FeyAgendaSpan

---@param options? FeyApiAgendaOptions
function FeyAgenda.agenda(options)
  options = options or {}
  local opts = get_shared_opts(options)
  opts.from = get_date(options.from, 'from')
  opts.span = options.span
  fey.agenda:agenda(opts)
end

---@class FeyApiAgendaTodosOptions:FeyApiAgendaOpts

---@param options? FeyApiAgendaTodosOptions
function FeyAgenda.todos(options)
  options = options or {}
  local opts = get_shared_opts(options)
  fey.agenda:todos(opts)
end

---@class FeyApiAgendaTagsTodoOptions:FeyApiAgendaOpts
---@field match_query? string Match query to find the todos
---@field fey_agenda_todo_ignore_scheduled? FeyAgendaTodoIgnoreScheduledTypes
---@field fey_agenda_todo_ignore_deadlines? FeyAgendaTodoIgnoreDeadlinesTypes

---@param options? FeyApiAgendaTagsOptions
function FeyAgenda.tags_todo(options)
  options = options or {}
  local opts = get_match_opts(options)
  fey.agenda:tags_todo(opts)
end

---@class FeyApiAgendaTagsOptions:FeyApiAgendaTagsTodoOptions
---@field todo_only? boolean

---@param options? FeyApiAgendaTagsOptions
function FeyAgenda.tags(options)
  options = options or {}
  local opts = get_match_opts(options)
  opts.todo_only = options.todo_only
  fey.agenda:tags(opts)
end

---@param key string Key in the agenda prompt (for example: "a", "t", "m", "M")
function FeyAgenda.open_by_key(key)
  return fey.agenda:open_by_key(key)
end

---Get the heading at the cursor position in the agenda view
---@return FeyApiHeading | nil
function FeyAgenda.get_heading_at_cursor()
  local entry = fey.agenda:get_heading_at_cursor()
  if not entry or not entry.abs then return nil end
  local file = require('fey.api').file(entry.abs)
  return file and file:heading_at(entry.line) or nil
end

return FeyAgenda
