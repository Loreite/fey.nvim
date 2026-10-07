local utils = require('fey.utils')
local Duration = require('fey.objects.duration')
local Entry = require('fey.agenda.entry')

-- The clock report of the agenda: the time clocked between two dates, by file and heading. It is one
-- query over the clocks of the vaults the agenda reads (`kind = clock` rows of `dates`), so there are no
-- logbooks to parse.

---@class FeyClockReport
---@field from FeyDate
---@field to FeyDate
---@field source FeyAgendaSource
local ClockReport = {}

---@param opts { from: FeyDate, to: FeyDate, source?: FeyAgendaSource }
---@return FeyClockReport
function ClockReport:new(opts)
  opts = opts or {}
  local data = {
    from = opts.from,
    to = opts.to,
    source = opts.source or require('fey.agenda.source').new(),
  }
  setmetatable(data, self)
  self.__index = self
  return data
end

---Rows for the agenda: each has `cells`, each cell its `content` (padded to the width of its column) and, for a
---heading, the `reference` the agenda jumps to
---@param _ number the line the table starts on, unused: the agenda places the rows
---@return { rows: { cells: { content: string, reference?: FeyAgendaEntry }[] }[] }
function ClockReport:get_table_report(_)
  local report = self:generate_report()
  local data = {
    { 'File', 'Heading', 'Time' },
    'hr',
    { '', 'ALL Total time', report.total_duration:to_string() },
    'hr',
  }

  for _, file in ipairs(report.files_with_clocks) do
    table.insert(data, { { value = file.name }, 'File time', file.total_duration:to_string() })
    for _, heading in ipairs(file.headings) do
      table.insert(data, {
        '',
        { value = heading:get_title(), reference = heading },
        Duration.from_minutes(heading.clocked_minutes):to_string(),
      })
    end
    table.insert(data, 'hr')
  end

  -- column widths over every row, then the cells padded to them; a rule is a row of dashes
  local widths = {}
  for _, row in ipairs(data) do
    if row ~= 'hr' then
      for i, cell in ipairs(row) do
        local text = type(cell) == 'table' and cell.value or cell
        widths[i] = math.max(widths[i] or 0, vim.api.nvim_strwidth(text))
      end
    end
  end
  local rows = {}
  for _, row in ipairs(data) do
    local cells = {}
    if row == 'hr' then
      for i, w in ipairs(widths) do
        cells[i] = { content = string.rep('-', w) }
      end
    else
      for i, cell in ipairs(row) do
        local text = type(cell) == 'table' and cell.value or cell
        cells[i] = { content = utils.pad_right(text, widths[i]), reference = type(cell) == 'table' and cell.reference or nil }
      end
    end
    rows[#rows + 1] = { cells = cells }
  end
  return { rows = rows }
end

---The clocks that start or end in the range, finished ones, with the headings they belong to
---@return { total_duration: FeyDuration, files_with_clocks: { name: string, total_duration: FeyDuration, headings: FeyAgendaEntry[] }[] }
function ClockReport:generate_report()
  local scope = require('fey.hollow.scope')
  local rows = scope.dates(
    self.source:get_scope(),
    self.source:get_root(),
    { kinds = { 'clock' }, from = self.from.timestamp, to = self.to.timestamp }
  )
  local files, order, entries = {}, {}, {}
  local total = 0
  for _, row in ipairs(rows) do
    local inside = (row.start_ts >= self.from.timestamp and row.start_ts <= self.to.timestamp)
      or (row.end_ts and row.end_ts >= self.from.timestamp and row.end_ts <= self.to.timestamp)
    if row.end_ts and inside and row.heading_ord and self.source:accepts(row.abs) then
      local minutes = Duration.from_seconds(row.end_ts - row.start_ts).minutes
      local file_key = row.hollow .. '\0' .. row.path
      local key = file_key .. '\0' .. row.heading_ord
      local entry = entries[key]
      if not entry then
        entry = Entry.from_row(row, 1)
        entry.clocked_minutes = 0
        entries[key] = entry
      end
      entry.clocked_minutes = entry.clocked_minutes + minutes
      local file = files[file_key]
      if not file then
        file = { name = entry:file_category() .. '.fey', minutes = 0, headings = {}, seen = {} }
        files[file_key] = file
        order[#order + 1] = file_key
      end
      file.minutes = file.minutes + minutes
      if not file.seen[key] then
        file.seen[key] = true
        file.headings[#file.headings + 1] = entry
      end
      total = total + minutes
    end
  end
  table.sort(order)
  local out = {}
  for _, key in ipairs(order) do
    local f = files[key]
    out[#out + 1] = { name = f.name, total_duration = Duration.from_minutes(f.minutes), headings = f.headings }
  end
  return { total_duration = Duration.from_minutes(total), files_with_clocks = out }
end

return ClockReport
