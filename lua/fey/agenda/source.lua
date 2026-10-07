-- Where the agenda gets its headings and dates from: the vaults of a scope (see `fey.hollow.scope`).
-- With the default scope, `court`, that is every hollow that takes part in the merged views, so a project
-- keeps its agenda in its own hollow and it shows up in the global one.
--
--   local source = require('fey.agenda.source').new({ scope = 'court' })
--   source:dates(from, to)  -- { { date = FeyDate, entry = FeyAgendaEntry }, ... }
--
-- The dates are read from the index, which is kept current while buffers are edited (`vault.live_index`),
-- so there is nothing to load and nothing to refresh.
local Date = require('fey.objects.date')
local Entry = require('fey.agenda.entry')
local scope = require('fey.hollow.scope')
local tree = require('fey.hollow.tree')

---@class FeyAgendaSource
---@field scope FeyScopeSpec
---@field paths? string[] limit to these files and directories (the deprecated `fey_agenda_files`)
---@field root? string the hollow `current` and `tree` start from
local Source = {}
Source.__index = Source

local DAY = 86400

local TYPES = { scheduled = 'SCHEDULED', deadline = 'DEADLINE', date = 'NONE' }

---@param opts? { scope?: FeyScopeSpec, paths?: string|string[], root?: string }
---@return FeyAgendaSource
function Source.new(opts)
  opts = opts or {}
  local self = setmetatable({ scope = opts.scope, root = opts.root }, Source)
  self:set_paths(opts.paths)
  return self
end

---The scope of the agenda: the configured one unless given. Falls back to `current` when the court is off.
---@return FeyScopeSpec
function Source:get_scope()
  local spec = self.scope or require('fey.config').fey_agenda_scope or 'court'
  if spec == 'court' and not require('fey.hollow.court').root() then return 'current' end
  return spec
end

---@return string|nil
function Source:get_root()
  return self.root or tree.hollow_root_of(vim.fn.getcwd())
end

---@param scope_spec? FeyScopeSpec
function Source:set_scope(scope_spec) self.scope = scope_spec end

---Limit the agenda to files and directories (`~` and glob patterns are expanded), like `fey_agenda_files`
---@param paths? string|string[]
function Source:set_paths(paths)
  if type(paths) == 'string' then paths = paths ~= '' and { paths } or nil end
  if not paths or #paths == 0 then
    self.paths = nil
    return
  end
  local out = {}
  for _, path in ipairs(paths) do
    for _, found in ipairs(vim.fn.glob(vim.fn.expand(path), true, true)) do
      out[#out + 1] = tree.realpath(found)
    end
  end
  self.paths = out
end

---The hollows the agenda looks at (ids), in the order of the scope
---@return string[]
function Source:hollows()
  local out = {}
  for _, v in ipairs((scope.resolve(self:get_scope(), self:get_root()))) do
    out[#out + 1] = v.id
  end
  return out
end

---Where the agenda looks, for a line of its own: `court (3 hollows)`, `current (court:alpha)`
---@return string
function Source:describe()
  local spec = self:get_scope()
  local hollows = self:hollows()
  local name = type(spec) == 'table' and table.concat(spec, ' ') or spec
  if #hollows == 1 then return ('%s (%s)'):format(name, hollows[1]) end
  return ('%s (%d hollows)'):format(name, #hollows)
end

---@param abs string
---@return boolean
function Source:accepts(abs)
  if not self.paths then return true end
  abs = tree.realpath(abs)
  for _, path in ipairs(self.paths) do
    if abs == path or vim.startswith(abs, path:gsub('/$', '') .. '/') then return true end
  end
  return false
end

---One date of the agenda as the dates of the heading would be: a range is the start and the end, linked
---@param row table
---@return FeyDate[]
local function dates_of(row)
  local type_ = TYPES[row.kind]
  if not type_ then return {} end
  local first = os.date('*t', row.start_ts)
  local adjustments = {}
  if row.repeater then adjustments[#adjustments + 1] = row.repeater end
  if row.warn then adjustments[#adjustments + 1] = row.warn end
  local has_time = row.start_time == 1
  ---@type FeyDateOpts
  local opts = {
    year = first.year,
    month = first.month,
    day = first.day,
    hour = has_time and first.hour or nil,
    min = has_time and first.min or nil,
    date_only = not has_time,
    type = type_,
    active = row.active == 1,
    adjustments = adjustments,
  }
  local start_date = Date:new(opts)
  if row.end_ts then
    local last = os.date('*t', row.end_ts)
    if last.year == first.year and last.month == first.month and last.day == first.day then
      -- the same day: a time range
      if row.end_time == 1 then start_date.timestamp_end = row.end_ts end
    else
      start_date.is_date_range_start = true
      local end_date = Date:new({
        year = last.year,
        month = last.month,
        day = last.day,
        hour = row.end_time == 1 and last.hour or nil,
        min = row.end_time == 1 and last.min or nil,
        date_only = row.end_time ~= 1,
        type = type_,
        active = row.active == 1,
        is_date_range_end = true,
        related_date = start_date,
      })
      start_date.related_date = end_date
      return { start_date, end_date }
    end
  end
  return { start_date }
end

---The dates of a heading the agenda looks at (the rules of `FeyHeading:get_valid_dates_for_agenda`)
---@param row table
---@return FeyDate[]
local function valid_dates(row)
  local out = {}
  for _, date in ipairs(dates_of(row)) do
    if date.active and not date:is_closed() and not date:is_obsolete_range_end() then
      out[#out + 1] = date
      if not date:is_none() and date.related_date then out[#out + 1] = date:clone({ type = 'NONE' }) end
    end
  end
  return out
end

---The headings with a date that may show in the range `from` to `to`: plain dates and ranges inside it,
---and every open planning date up to the end of it (an overdue scheduled item stays on the agenda, a
---deadline shows up some days ahead), with whatever repeats.
---@param from FeyDate
---@param to FeyDate
---@return { date: FeyDate, entry: FeyAgendaEntry }[]
function Source:dates(from, to)
  local spec, root = self:get_scope(), self:get_root()
  local margin = (require('fey.config').fey_deadline_warning_days or 14) * 2 * DAY
  local to_ts = to.timestamp
  local rows = {}
  local function add(list) vim.list_extend(rows, list) end
  add(scope.dates(spec, root, { kinds = { 'scheduled', 'deadline' }, active = true, to = to_ts + 366 * DAY }))
  add(scope.dates(spec, root, { kinds = { 'date' }, active = true, from = from.timestamp - margin, to = to_ts }))

  local entries, files, out = {}, {}, {}
  for _, row in ipairs(rows) do
    if row.heading_ord and self:accepts(row.abs) then
      local file_key = row.hollow .. '\0' .. row.path
      files[file_key] = files[file_key] or (vim.tbl_count(files) + 1)
      local key = file_key .. '\0' .. row.heading_ord
      local entry = entries[key]
      if not entry then
        entry = Entry.from_row(row, files[file_key])
        entries[key] = entry
      end
      for _, date in ipairs(valid_dates(row)) do
        date.row = { hollow = row.hollow, abs = row.abs, path = row.path, line = row.line, col = row.col, kind = row.kind }
        out[#out + 1] = { date = date, entry = entry }
      end
    end
  end
  return out
end

return Source
