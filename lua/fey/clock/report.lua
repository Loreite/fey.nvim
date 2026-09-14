local Table = require('fey.files.elements.table')
local Duration = require('fey.objects.duration')

---@class FeyClockReport
---@field from FeyDate
---@field to FeyDate
---@field table FeyTable
---@field files FeyFiles
local ClockReport = {}

---@param opts { from: FeyDate, to: FeyDate, files: FeyFiles }
---@return FeyClockReport
function ClockReport:new(opts)
  opts = opts or {}
  local data = {}
  data.from = opts.from
  data.to = opts.to
  data.files = opts.files
  setmetatable(data, self)
  self.__index = self
  return data
end

---@param start_line number
---@return FeyTable
function ClockReport:get_table_report(start_line)
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
        heading:get_logbook():get_total(self.from, self.to):to_string(),
      })
    end
    table.insert(data, 'hr')
  end

  return Table.from_list(data, start_line, 0):compile()
end

function ClockReport:generate_report()
  local total_duration = 0
  local files_with_clocks = {}
  for _, feyfile in ipairs(self.files:all()) do
    local file_clocks = self:_get_clock_report_for_file(feyfile)
    if #file_clocks.headings > 0 then
      total_duration = total_duration + file_clocks.total_duration.minutes
      table.insert(files_with_clocks, {
        name = feyfile:get_category() .. '.fey',
        total_duration = file_clocks.total_duration,
        headings = file_clocks.headings,
      })
    end
  end

  return {
    total_duration = Duration.from_minutes(total_duration),
    files_with_clocks = files_with_clocks,
  }
end

---@private
---@param feyfile FeyFile
function ClockReport:_get_clock_report_for_file(feyfile)
  local total_duration = 0
  local headings = {}
  for _, heading in ipairs(feyfile:get_headings()) do
    local logbook = heading:get_logbook()
    if logbook then
      local minutes = logbook:get_total_minutes(self.from, self.to)
      if minutes > 0 then
        table.insert(headings, heading)
        total_duration = total_duration + minutes
      end
    end
  end

  return {
    headings = headings,
    total_duration = Duration.from_minutes(total_duration),
  }
end

return ClockReport
