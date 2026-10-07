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

---A source like this one with other settings (`scope`, `root`), sharing nothing that changes
---@param opts { scope?: FeyScopeSpec, root?: string, paths?: string|string[] }
---@return FeyAgendaSource
function Source:with(opts)
  local clone = Source.new({ scope = opts.scope or self.scope, root = opts.root or self.root })
  clone.paths = opts.paths and nil or self.paths
  if opts.paths then clone:set_paths(opts.paths) end
  return clone
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

---The headings with a running clock, as a set of `hollow \0 path \0 ord`
---@return table<string, boolean>
function Source:clocked()
  local rows = scope.collect(self:get_scope(), self:get_root(), function(vault)
    return vault:query(
      [[SELECT f.path, d.heading_ord FROM dates d JOIN files f ON f.id = d.file_id
        WHERE d.kind = 'clock' AND d.end_ts IS NULL AND d.heading_ord IS NOT NULL]]
    )
  end)
  local set = {}
  for _, r in ipairs(rows) do
    set[r.hollow .. '\0' .. r.path .. '\0' .. r.heading_ord] = true
  end
  return set
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

Source.dates_of = dates_of

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
  local clocked = self:clocked()
  for _, row in ipairs(rows) do
    if row.heading_ord and self:accepts(row.abs) then
      local file_key = row.hollow .. '\0' .. row.path
      files[file_key] = files[file_key] or (vim.tbl_count(files) + 1)
      local key = file_key .. '\0' .. row.heading_ord
      local entry = entries[key]
      if not entry then
        entry = Entry.from_row(row, files[file_key])
        entry._clocked = clocked[key] or false
        entries[key] = entry
      end
      local skip = entry:is_archived() and require('fey.config').fey_agenda_skip_archived ~= false
      for _, date in ipairs(skip and {} or valid_dates(row)) do
        date.row = { hollow = row.hollow, abs = row.abs, path = row.path, line = row.line, col = row.col, kind = row.kind }
        out[#out + 1] = { date = date, entry = entry }
      end
    end
  end
  return out
end

---Open planning dates (deadline and scheduled) of the headings, for reminders: whatever starts between the
---two times (epoch seconds), and everything that repeats
---@param from integer
---@param to integer
---@return { date: FeyDate, entry: FeyAgendaEntry }[]
function Source:planning(from, to)
  local rows = scope.dates(
    self:get_scope(),
    self:get_root(),
    { kinds = { 'scheduled', 'deadline' }, active = true, open_only = true, from = from, to = to }
  )
  local out, entries = {}, {}
  for _, row in ipairs(rows) do
    if row.heading_ord and self:accepts(row.abs) then
      local key = row.hollow .. '\0' .. row.path .. '\0' .. row.heading_ord
      local entry = entries[key]
      if not entry then
        entry = Entry.from_row(row, 1)
        entries[key] = entry
      end
      if not entry:is_archived() then
        local date = dates_of(row)[1]
        if date then out[#out + 1] = { date = date, entry = entry } end
      end
    end
  end
  return out
end

---Every heading of the scope as an entry, for the views that list headings
---@param opts? { todo_only?: boolean } `todo_only` keeps the open todo items (a keyword that is not a done one)
---@return FeyAgendaEntry[]
function Source:headings(opts)
  opts = opts or {}
  local rows = scope.collect(self:get_scope(), self:get_root(), function(vault) return vault:agenda_headings() end)
  local files, out = {}, {}
  local clocked = self:clocked()
  for _, row in ipairs(rows) do
    if self:accepts(row.abs) then
      local file_key = row.hollow .. '\0' .. row.path
      files[file_key] = files[file_key] or (vim.tbl_count(files) + 1)
      local entry = Entry.from_row(row, files[file_key])
      entry._clocked = clocked[file_key .. '\0' .. row.ord] or false
      local archived = entry:is_archived() and require('fey.config').fey_agenda_skip_archived ~= false
      if not archived and (not opts.todo_only or entry:is_todo()) then
        entry.index = #out + 1
        out[#out + 1] = entry
      end
    end
  end
  return out
end

---The labels in use in the scope, sorted, for completion
---@return string[]
function Source:labels()
  local seen, out = {}, {}
  for _, item in ipairs(scope.labels(self:get_scope(), self:get_root())) do
    seen[item.label] = true
    out[#out + 1] = item.label
  end
  table.sort(out)
  return out
end

---Headings whose title or text has the term (a Lua pattern, lower case), with the text of the heading read
---from the buffer when it is loaded, else from the file
---@param term string
---@return FeyAgendaEntry[]
function Source:search(term)
  term = term:lower()
  local cache = {}
  local function lines_of(abs)
    if cache[abs] == nil then
      local buf = vim.fn.bufnr(abs)
      if buf > 0 and vim.api.nvim_buf_is_loaded(buf) then
        cache[abs] = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      elseif vim.fn.filereadable(abs) == 1 then
        cache[abs] = vim.fn.readfile(abs)
      else
        cache[abs] = {}
      end
    end
    return cache[abs]
  end
  local out = {}
  local all = self:headings()
  for i, entry in ipairs(all) do
    local ok = pcall(function()
      if entry:get_title():lower():match(term) then
        out[#out + 1] = entry
      else
        -- the text of the heading itself, up to the next heading
        local lines = lines_of(entry.abs)
        local following = all[i + 1]
        local last = (following and following.abs == entry.abs) and (following.line - 1) or #lines
        local body = table.concat(lines, '\n', math.min(entry.line + 1, #lines + 1), math.min(last, #lines))
        if body:lower():match(term) then out[#out + 1] = entry end
      end
    end)
    if not ok then return {} end
  end
  for i, entry in ipairs(out) do
    entry.index = i
  end
  return out
end

return Source
