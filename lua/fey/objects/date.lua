---@type FeyDateSpan
local spans = { d = 'day', m = 'month', y = 'year', h = 'hour', w = 'week', M = 'min' }
local config = require('fey.config')
local utils = require('fey.utils')
local ts_utils = require('fey.utils.treesitter')
local Range = require('fey.files.elements.range')
local pattern = '([<%[])(%d%d%d%d%-%d?%d%-%d%d[^>%]]*)([>%]])'
local date_format = '%Y-%m-%d'
local time_format = '%H:%M'

---@alias FeyDateSpan 'hour' | 'day' | 'week' | 'month' | 'year' | string

---@class FeyDateSetOpts
---@field day? number
---@field month? number
---@field year? number
---@field hour? number
---@field min? number
---@field date_only? boolean
---@field type? string
---@field range? FeyRange
---@field active? boolean
---@field adjustments? string[]
---
---@class FeyDateOpts:FeyDateSetOpts
---@field timestamp_end? number
---@field is_date_range_start? boolean
---@field is_date_range_end? boolean
---@field related_date? FeyDate

---@class FeyDate
---@field day number
---@field month number
---@field year number
---@field hour number
---@field min number
---@field date_only boolean
---@field wday number
---@field isdst boolean
---@field type string
---@field dayname string
---@field range? FeyRange
---@field active boolean
---@field adjustments string[]
---@field timestamp number
---@field timestamp_end? number
---@field is_date_range_start boolean
---@field is_date_range_end boolean
---@field related_date? FeyDate
local FeyDate = {
  pattern = pattern,
  ---@type fun(this: FeyDate, other: FeyDate): boolean
  __eq = function(this, other)
    return this:is_same(other)
  end,
  ---@type fun(this: FeyDate, other: FeyDate): boolean
  __lt = function(this, other)
    return this:is_before(other)
  end,
  ---@type fun(this: FeyDate, other: FeyDate): boolean
  __le = function(this, other)
    return this:is_same_or_before(other)
  end,
  ---@type fun(this: FeyDate, other: FeyDate): boolean
  __gt = function(this, other)
    return this:is_after(other)
  end,
  ---@type fun(this: FeyDate, other: FeyDate): boolean
  __ge = function(this, other)
    return this:is_same_or_after(other)
  end,
}
FeyDate.__index = FeyDate

---@param timestamp number
---@param format? string
---@return osdate
local function os_date(timestamp, format)
  if format and vim.fn.has('win32') == 1 then
    local locale = os.setlocale(nil, 'time')
    local utf8_locale
    if locale then
      if vim.endswith(locale, 'UTF-8') then
        utf8_locale = locale
      else
        utf8_locale = locale:gsub('%.[^.]+$', '') .. '.UTF-8'
      end
    end
    local changed_locale = utf8_locale and os.setlocale(utf8_locale, 'time')
    if changed_locale then
      local date = os.date(format, timestamp)
      os.setlocale(locale, 'time')
      return date --[[@as osdate]]
    end
  end

  return os.date(format or '*t', timestamp) --[[@as osdate]]
end

---@param date string
---@param time string
---@param adjustments string[]
---@param data FeyDateOpts
---@return FeyDate
local function parse_datetime(date, time, time_end, adjustments, data)
  local date_parts = vim.split(date, '-')
  local time_parts = vim.split(time, ':')

  ---@type FeyDateOpts
  local opts = {
    year = tonumber(date_parts[1]) or 0,
    month = tonumber(date_parts[2]) or 0,
    day = tonumber(date_parts[3]) or 0,
    hour = tonumber(time_parts[1]) or 0,
    min = tonumber(time_parts[2]) or 0,
  }
  opts.adjustments = adjustments
  if time_end then
    local time_end_parts = vim.split(time_end, ':')
    opts.timestamp_end = os.time({
      year = tonumber(date_parts[1]) or 0,
      month = tonumber(date_parts[2]) or 0,
      day = tonumber(date_parts[3]) or 0,
      hour = tonumber(time_end_parts[1]) or 0,
      min = tonumber(time_end_parts[2]) or 0,
    })
  end
  opts = vim.tbl_extend('force', opts, data or {})
  return FeyDate:new(opts)
end

---@param date string
---@param adjustments string[]
---@param data FeyDateOpts
---@return FeyDate
local function parse_date(date, adjustments, data)
  local date_parts = vim.split(date, '-')
  ---@type FeyDateOpts
  local opts = {
    year = tonumber(date_parts[1]) or 0,
    month = tonumber(date_parts[2]) or 0,
    day = tonumber(date_parts[3]) or 0,
  }
  opts.adjustments = adjustments
  opts = vim.tbl_extend('force', opts, data or {})
  return FeyDate:new(opts)
end

---@param opts FeyDateOpts
---@return FeyDate
function FeyDate:new(opts)
  local data = {}
  data.date_only = opts.date_only or (not opts.hour and not opts.min)
  data.timestamp = os.time({
    year = opts.year,
    month = opts.month,
    day = opts.day,
    hour = opts.hour or 0,
    min = opts.min or 0,
  })
  local date_info = os_date(data.timestamp)
  data.day = date_info.day
  data.month = date_info.month
  data.year = date_info.year
  data.hour = date_info.hour
  data.min = date_info.min
  data.isdst = date_info.isdst
  data.wday = date_info.wday

  data.active = opts.active or false
  data.type = opts.type or 'NONE'
  data.range = opts.range
  data.dayname = os_date(data.timestamp, '%a') --[[@as string]]
  data.adjustments = opts.adjustments or {}
  data.timestamp_end = opts.timestamp_end
  data.is_date_range_start = opts.is_date_range_start or false
  data.is_date_range_end = opts.is_date_range_end or false
  data.related_date = opts.related_date or nil

  return setmetatable(data, self)
end

---@param opts FeyDateSetOpts
---@return FeyDate
function FeyDate:set(opts)
  local data = {
    day = self.day,
    month = self.month,
    year = self.year,
    hour = self.hour,
    min = self.min,
    date_only = self.date_only,
    type = self.type,
    range = self.range,
    active = self.active,
    adjustments = self.adjustments,
    is_date_range_start = self.is_date_range_start,
    is_date_range_end = self.is_date_range_end,
    related_date = self.related_date,
  }

  if type(opts.date_only) == 'boolean' then
    data.date_only = opts.date_only
  end

  for key, value in pairs(opts) do
    data[key] = value
  end

  if self.timestamp_end then
    local range_diff = self.timestamp_end - self.timestamp
    local timestamp = os.time(data)
    data.timestamp_end = timestamp + range_diff
  end

  return FeyDate:new(data)
end

---@param value string date in string format, example: 2025-03-07 Fri
---@return FeyDate | nil
function FeyDate:set_from_string(value)
  return FeyDate.from_string(value, {
    type = self.type,
    range = self.range,
    active = self.active,
    is_date_range_start = self.is_date_range_start,
    is_date_range_end = self.is_date_range_end,
    related_date = self.related_date,
  })
end

---@param opts? FeyDateOpts
function FeyDate:clone(opts)
  return self:set(opts or {})
end

---Return todays date without the time
---@param opts? FeyDateOpts
---@return FeyDate
function FeyDate.today(opts)
  opts = opts or {}
  opts.date_only = true
  return FeyDate.from_timestamp(os.time(), opts)
end

---Return current date and time
---@param opts? FeyDateOpts
---@return FeyDate
function FeyDate.now(opts)
  return FeyDate.from_timestamp(os.time(), opts)
end

---Return tomorrows date without the time
---@param opts? FeyDateOpts
---@return FeyDate
function FeyDate.tomorrow(opts)
  local today = FeyDate.today(opts)
  return today:adjust('+1d')
end

---@param timestamp number
---@param opts? FeyDateOpts
---@return FeyDate
function FeyDate.from_timestamp(timestamp, opts)
  local date = os_date(timestamp)
  local data = {
    day = date.day,
    month = date.month,
    year = date.year,
  }
  if not opts or not opts.date_only then
    data.hour = date.hour
    data.min = date.min
  end
  if opts then
    data = vim.tbl_extend('force', opts, data)
  end
  return FeyDate:new(data)
end

---@param node TSNode | nil
---@param source? integer | string
---@param opts? FeyDateOpts
---@return FeyDate[]
function FeyDate.from_node(node, source, opts)
  if not node then
    return {}
  end
  opts = opts or {}
  opts.range = opts.range or Range.from_node(node)
  source = source or 0
  if not opts.type then
    opts.type = ts_utils.is_date_in_drawer(node, 'logbook', source) and 'LOGBOOK' or 'NONE'
  end
  return FeyDate.from_fey_date(vim.treesitter.get_node_text(node, source), opts)
end

---Accept fey format date, for example <2025-22-01 Wed> or range <2025-22-01 Wed>--<2025-24-01 Fri>
---@param datestr string
---@param opts? FeyDateOpts
---@return FeyDate[]
function FeyDate.from_fey_date(datestr, opts)
  opts = opts or {}
  local from_open, from, from_close, delimiter, to_open, to, to_close = datestr:match(pattern .. '(%-%-)' .. pattern)
  if not delimiter then
    if not FeyDate.is_valid_date_string(datestr:sub(2, -2)) then
      return {}
    end
    local is_active = datestr:sub(1, 1) == '<' and datestr:sub(-1) == '>'
    local dateval = datestr:gsub('^[%[<]', ''):gsub('[%]>]', '')
    opts = opts or {}
    opts.active = is_active
    return { FeyDate.from_string(dateval, opts) }
  end

  local line = opts.range.start_line
  local start_date = FeyDate.from_string(
    from,
    vim.tbl_extend('force', opts or {}, {
      active = from_open == '<' and from_close == '>',
      is_date_range_start = true,
      range = Range:new({
        start_line = line,
        end_line = line,
        start_col = opts.range.start_col,
        end_col = opts.range.start_col + (from_open .. from .. from_close):len() - 1,
      }),
    })
  )

  local end_date = FeyDate.from_string(
    to,
    vim.tbl_extend('force', opts or {}, {
      active = to_open == '<' and to_close == '>',
      is_date_range_end = true,
      range = Range:new({
        start_line = line,
        end_line = line,
        start_col = start_date and start_date.range.end_col + 3,
        end_col = opts.range.end_col,
      }),
      related_date = start_date,
    })
  )
  if end_date then
    start_date.related_date = end_date
  end

  return { start_date, end_date }
end

---@param datestr string
---@return boolean
function FeyDate.is_valid_date_string(datestr)
  return datestr:match('^%d%d%d%d%-%d%d%-%d%d%s+') or datestr:match('^%d%d%d%d%-%d%d%-%d%d$')
end

---@param value any
---@return boolean
function FeyDate.is_date_instance(value)
  return getmetatable(value) == FeyDate
end

---@param datestr string
---@param opts? FeyDateOpts
---@return FeyDate | nil
function FeyDate.from_string(datestr, opts)
  if not FeyDate.is_valid_date_string(datestr) then
    return nil
  end
  local parts = vim.split(datestr, '%s+')
  local date = table.remove(parts, 1)
  local time = nil
  local time_end = nil
  local adjustments = {}
  for _, part in ipairs(parts) do
    if part:match('%d?%d:%d%d%-%d?%d:%d%d') then
      local times = vim.split(part, '-')
      time = times[1]
      time_end = times[2]
    elseif part:match('%d?%d:%d%d') then
      time = part
    elseif part:match('[%.%+%-]+%d+[hdwmy]?') then
      table.insert(adjustments, part)
    end
  end

  if time then
    return parse_datetime(date, time, time_end, adjustments, opts or {})
  end

  return parse_date(date, adjustments, opts or {})
end

--- @return { type: 'date' | 'dayname' | 'time' | 'time_range' | 'adjustment', value: string, from: number, to: number }[]
function FeyDate:parse_parts()
  local result = {}
  local counter = 1
  local patterns = {
    { type = 'date', rgx = '^%d%d%d%d%-%d%d%-%d%d$' },
    { type = 'dayname', rgx = '^%a%a%a$' },
    { type = 'time', rgx = '^%d?%d:%d%d$' },
    { type = 'time_range', rgx = '^%d?%d:%d%d%-%d?%d:%d%d$' },
    { type = 'adjustment', rgx = '^[%.%+%-]+%d+[hdwmy]?$' },
  }
  for space, item in string.gmatch(self:to_string(), '(%s*)(%S+)') do
    local from = counter + space:len()
    for _, dt_pattern in ipairs(patterns) do
      if item:match(dt_pattern.rgx) then
        table.insert(result, {
          type = dt_pattern.type,
          value = item,
          from = from,
          to = from + item:len() - 1,
        })
        counter = counter + item:len() + space:len()
      end
    end
  end
  return result
end

---@return string
function FeyDate:to_string()
  local format = date_format
  if self.dayname then
    format = format .. ' %a'
  end

  local date = tostring(os_date(self.timestamp, format))

  if self:has_time() then
    date = date .. ' ' .. self:format_time()
  end

  if #self.adjustments > 0 then
    date = date .. ' ' .. table.concat(self.adjustments, ' ')
  end

  return date
end

---@return string
function FeyDate:to_date_string()
  local old_date_only = self.date_only
  self.date_only = true
  local result = self:to_string()
  self.date_only = old_date_only
  return result
end

---@param active boolean | nil
---@return string
function FeyDate:to_wrapped_string(active)
  if type(active) ~= 'boolean' then
    active = self.active
  end
  local date = self:to_string()
  local open = active and '<' or '['
  local close = active and '>' or ']'
  return string.format('%s%s%s', open, date, close)
end

---@param format string
---@return string
function FeyDate:format(format)
  return tostring(os_date(self.timestamp, format))
end

---@return string
function FeyDate:format_time()
  if not self:has_time() then
    return ''
  end
  local t = self:format(time_format)
  if self.timestamp_end then
    t = t .. '-' .. os_date(self.timestamp_end, time_format)
  end
  return t
end

---@return boolean
function FeyDate:has_time()
  return not self.date_only
end

---@param value string
---@return FeyDate
function FeyDate:adjust(value)
  local adjustment = self:_parse_adjustment(value)
  local modifier = { [adjustment.span] = adjustment.amount }
  if adjustment.is_negative then
    return self:subtract(modifier)
  end
  return self:add(modifier)
end

---@param value string
---@return FeyDate
function FeyDate:adjust_end_time(value)
  if not self.timestamp_end then
    return self
  end
  local time_end = FeyDate.from_timestamp(self.timestamp_end)
  time_end = time_end:adjust(value)
  self.timestamp_end = time_end.timestamp
  return self
end

---@param value string
---@return table
function FeyDate:_parse_adjustment(value)
  local operation, amount, span = value:match('^([%+%-])(%d+)([hdwmyM]?)')
  if not operation or not amount then
    return { span = 'day', amount = 0 }
  end
  if not span or span == '' then
    span = 'd'
  end
  return {
    span = spans[span],
    amount = tonumber(amount),
    is_negative = operation == '-',
  }
end

---@return FeyDate
function FeyDate:without_adjustments()
  return self:clone({ adjustments = {} })
end

---@param span FeyDateSpan
---@return FeyDate
function FeyDate:start_of(span)
  if #span == 1 then
    span = spans[span]
  end
  local opts = {
    day = { hour = 0, min = 0 },
    month = { day = 1, hour = 0, min = 0 },
    year = { month = 1, day = 1, hour = 0, min = 0 },
    hour = { min = 0 },
  }
  if opts[span] then
    return self:set(opts[span])
  end

  if span == 'week' then
    local this = self
    while this.wday ~= config:get_week_start_day_number() do
      this = this:adjust('-1d')
    end
    return this:set(opts.day)
  end

  return self
end

---@param span FeyDateSpan
---@return FeyDate
function FeyDate:end_of(span)
  if #span == 1 then
    span = spans[span]
  end
  local opts = {
    day = { hour = 23, min = 59 },
    year = { month = 12, day = 31, hour = 23, min = 59 },
    hour = { min = 59 },
  }

  if opts[span] then
    return self:set(opts[span])
  end

  if span == 'week' then
    local this = self
    while this.wday ~= config:get_week_end_day_number() do
      this = this:adjust('+1d')
    end
    return this:set(opts.day)
  end

  if span == 'month' then
    local date = os_date(self.timestamp)
    return self:set({ day = FeyDate._days_of_month(date) }):end_of('day')
  end

  return self
end

---@return FeyDate
function FeyDate:last_day_of_month()
  return self:set({ day = FeyDate._days_of_month(os_date(self.timestamp)) })
end

---@return number
function FeyDate:get_isoweekday()
  return utils.convert_to_isoweekday(self.wday)
end

---@return number
function FeyDate:get_weekday()
  return tonumber(self.wday) or 0
end

---@param isoweekday number
---@param future? boolean
---@return FeyDate
function FeyDate:set_isoweekday(isoweekday, future)
  local current_isoweekday = self:get_isoweekday()
  if isoweekday <= current_isoweekday then
    return self:subtract({ day = current_isoweekday - isoweekday })
  end
  if future then
    return self:add({ day = isoweekday - current_isoweekday })
  end
  return self:subtract({ week = 1 }):add({ day = isoweekday - current_isoweekday })
end

---@param opts FeyDateSetOpts
---@return FeyDate
function FeyDate:add(opts)
  opts = opts or {}
  ---@type table
  ---@diagnostic disable-next-line: assign-type-mismatch
  local date = os_date(self.timestamp)
  for opt, val in pairs(opts) do
    if opt == 'week' then
      opt = 'day'
      val = val * 7
    end
    date[opt] = date[opt] + val
  end
  if opts['month'] then
    date['day'] = math.min(date['day'], FeyDate._days_of_month(date))
  end
  return self:set(date)
end

---@param date osdate
---@return number
function FeyDate._days_of_month(date)
  local days_of = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
  local month = date.month

  if month == 2 then
    return FeyDate._days_of_february(date.year)
  end

  if month >= 1 and month <= 12 then
    return days_of[month]
  end

  -- In case the month goes below or above the threshold (via adding or subtracting)
  -- We need to adjust it to be within the range of 1-12
  -- by either adding or subtracting
  if month < 1 then
    month = 12 - month
  end

  if month > 12 then
    month = month - 12
  end

  return days_of[month]
end

---@return number
function FeyDate._days_of_february(year)
  return FeyDate._is_leap_year(year) and 29 or 28
end

---@return boolean
function FeyDate._is_leap_year(year)
  return year % 400 == 0 or (year % 100 ~= 0 and year % 4 == 0)
end

---@param opts FeyDateSetOpts
---@return FeyDate
function FeyDate:subtract(opts)
  opts = opts or {}
  for opt, val in pairs(opts) do
    opts[opt] = -val
  end
  return self:add(opts)
end

---@return number
function FeyDate:get_comparable_timestamp()
  if self.date_only then
    return self:start_of('day').timestamp
  end
  return self.timestamp
end

---@param date FeyDate
---@param span? FeyDateSpan
---@return boolean
function FeyDate:is_same(date, span)
  if span then
    return self:start_of(span).timestamp == date:start_of(span).timestamp
  end
  return self:get_comparable_timestamp() == date:get_comparable_timestamp()
end

---@param from FeyDate
---@param to FeyDate
---@param span FeyDateSpan
---@return boolean
function FeyDate:is_between(from, to, span)
  local f = from
  local t = to
  if span then
    f = from:start_of(span)
    t = to:end_of(span)
  end
  local self_ts = self:get_comparable_timestamp()
  local from_ts = f:get_comparable_timestamp()
  local to_ts = t:get_comparable_timestamp()
  return self_ts >= from_ts and self_ts <= to_ts
end

---@param date FeyDate
---@param span? FeyDateSpan
---@return boolean
function FeyDate:is_before(date, span)
  return not self:is_same_or_after(date, span)
end

---@param date FeyDate
---@param span? FeyDateSpan
---@return boolean
function FeyDate:is_same_or_before(date, span)
  local d = date
  local s = self
  if span then
    d = date:start_of(span)
    s = self:start_of(span)
  end
  return s:get_comparable_timestamp() <= d:get_comparable_timestamp()
end

---@param date FeyDate
---@param span? FeyDateSpan
---@return boolean
function FeyDate:is_after(date, span)
  return not self:is_same_or_before(date, span)
end

---@param date FeyDate
---@param span FeyDateSpan?
---@return boolean
function FeyDate:is_same_or_after(date, span)
  local d = date
  local s = self
  if span then
    d = date:start_of(span)
    s = self:start_of(span)
  end
  return s:get_comparable_timestamp() >= d:get_comparable_timestamp()
end

---@return boolean
function FeyDate:is_today()
  if self.is_today_date == nil then
    local date = FeyDate.now()
    self.is_today_date = self:is_same_day(date)
  end
  return self.is_today_date
end

---@return boolean
function FeyDate:is_same_day(date)
  return date and date.year == self.year and date.month == self.month and date.day == self.day
end

---@return boolean
function FeyDate:is_obsolete_range_end()
  return self.is_date_range_end and self.related_date:is_same(self, 'day')
end

---@return boolean
function FeyDate:has_date_range_end()
  return self.related_date ~= nil and self.is_date_range_start
end

---@return boolean
function FeyDate:has_time_range()
  return self.timestamp_end ~= nil
end

---@return FeyDate | nil
function FeyDate:get_date_range_end()
  return self:has_date_range_end() and self.related_date or nil
end

---@return number
function FeyDate:get_type_sort_value()
  local types = {
    DEADLINE = 1,
    SCHEDULED = 2,
    NONE = 3,
  }
  return types[self.type]
end

---@return number number of days for a date range
function FeyDate:get_date_range_days()
  if not self:is_none() or not self.related_date then
    return 0
  end
  return math.abs(self.related_date:diff(self)) + 1
end

---@param date FeyDate
---@return boolean
function FeyDate:is_in_date_range(date)
  if self.is_date_range_start then
    local ranges_same_day = self.related_date:is_obsolete_range_end()
    if ranges_same_day then
      return false
    end
    return date:is_between(self, self.related_date:subtract({ day = 1 }), 'day')
  end
  return false
end

---Range of dates, excluding date
---@param date FeyDate
---@return FeyDate[]
function FeyDate:get_range_until(date)
  local this = self
  local dates = {}
  while this.timestamp < date.timestamp do
    table.insert(dates, this)
    this = this:add({ day = 1 })
  end
  return dates
end

---@param from FeyDate
---@param span? 'day' | 'minute'
---@return number
function FeyDate:diff(from, span)
  span = span or 'day'
  local to_date = self:start_of(span)
  local from_date = from:start_of(span)
  local diff = to_date.timestamp - from_date.timestamp
  if to_date.isdst ~= from_date.isdst then
    diff = diff + (to_date.isdst and 3600 or -3600)
  end
  local durations = {
    day = 86400,
    minute = 60,
  }
  return math.floor(diff / durations[span])
end

---@param span FeyDateSpan
---@return boolean
function FeyDate:is_past(span)
  return self:is_before(FeyDate.now(), span)
end

---@param span FeyDateSpan
---@return boolean
function FeyDate:is_today_or_past(span)
  return self:is_same_or_before(FeyDate.now(), span)
end

---@param span FeyDateSpan
---@return boolean
function FeyDate:is_future(span)
  return self:is_after(FeyDate.now(), span)
end

---@param span FeyDateSpan
---@return boolean
function FeyDate:is_today_or_future(span)
  return self:is_same_or_after(FeyDate.now(), span)
end

---@param from FeyDate
---@return string
function FeyDate:humanize(from)
  from = from or FeyDate.now()
  local diff = self:diff(from)
  if diff == 0 then
    return 'Today'
  end
  if diff < 0 then
    return math.abs(diff) .. ' d. ago'
  end
  return 'In ' .. diff .. ' d.'
end

---@return boolean
function FeyDate:is_deadline()
  return self.active and self.type == 'DEADLINE'
end

---@return boolean
function FeyDate:is_none()
  return self.active and self.type == 'NONE'
end

---@return boolean
function FeyDate:is_logbook()
  return self.type == 'LOGBOOK'
end

---@return boolean
function FeyDate:is_scheduled()
  return self.active and self.type == 'SCHEDULED'
end

---@return boolean
function FeyDate:is_closed()
  return self.type == 'CLOSED'
end

---@return boolean
function FeyDate:is_planning_date()
  return self:is_deadline() or self:is_scheduled() or self:is_closed()
end

---@return boolean
function FeyDate:is_weekend()
  local isoweekday = self:get_isoweekday()
  return isoweekday >= 6
end

---@return table | nil
function FeyDate:get_negative_adjustment()
  if #self.adjustments == 0 then
    return nil
  end
  for _, adj in ipairs(self.adjustments) do
    if adj:match('^%-%d+') then
      return self:_parse_adjustment(adj)
    end
  end
  return nil
end

---@return FeyDate
function FeyDate:with_negative_adjustment()
  local adj = self:get_negative_adjustment()
  if not adj then
    return self
  end

  if self:is_deadline() then
    return self:subtract({ [adj.span] = adj.amount })
  end

  if self:is_scheduled() then
    return self:add({ [adj.span] = adj.amount })
  end

  return self
end

---Get repeater value (ex. +1w, .+1w, ++1w)
---@return string | nil
function FeyDate:get_repeater()
  if #self.adjustments == 0 then
    return nil
  end

  for _, adj in ipairs(self.adjustments) do
    if adj:match('^[%+%.]?%+%d+') then
      return adj
    end
  end
  return nil
end

---@return FeyDate
function FeyDate:set_todays_date()
  local time = os_date(os.time())
  return self:set({
    year = tonumber(time.year) or 0,
    month = tonumber(time.month) or 0,
    day = tonumber(time.day) or 0,
  })
end

function FeyDate:set_current_time()
  local time = os_date(os.time())
  return self:set({
    hour = tonumber(time.hour) or 0,
    min = tonumber(time.min) or 0,
  })
end

---@return FeyDate
function FeyDate:apply_repeater()
  local repeater = self:get_repeater()
  local date = self
  local current_time = FeyDate.now()
  if not repeater then
    return self
  end

  -- Repeater relative to completion time
  if repeater:match('^%.%+%d+') then
    -- Strip the '.' from the repeater
    local offset = repeater:sub(2)
    return date:set_todays_date():adjust(offset)
  end

  -- Repeater relative to deadline/scheduled date
  if repeater:match('^%+%+%d') then
    -- Strip the '+' from the repeater
    local offset = repeater:sub(2)
    repeat
      date = date:adjust(offset)
    until date.timestamp > current_time.timestamp
    return date
  end

  -- Simple repeat; apply repeater once to deadline/scheduled date
  return date:adjust(repeater)
end

---@param date FeyDate
---@param repeat_count number | nil
---@return boolean
function FeyDate:repeats_on(date, repeat_count)
  local repeater = self:get_repeater()
  if not repeater then
    return false
  end
  if repeat_count == 0 then
    return false
  end
  repeater = repeater:gsub('^%.', ''):gsub('^%+%+', '+')
  local repeat_date = self:start_of('day')
  local date_start = date:start_of('day')
  local counter = 0
  while repeat_date.timestamp < date_start.timestamp do
    if repeat_count and counter >= repeat_count then
      break
    end
    counter = counter + 1
    repeat_date = repeat_date:adjust(repeater)
  end
  return repeat_date:is_same(date, 'day')
end

---@param date FeyDate
function FeyDate:apply_repeater_until(date)
  local repeater = self:get_repeater()
  if not repeater then
    return self
  end

  repeater = repeater:gsub('^%.', ''):gsub('^%+%+', '+')
  local repeat_date = self

  while repeat_date.timestamp < date.timestamp do
    repeat_date = repeat_date:adjust(repeater)
  end

  return repeat_date
end

---@return FeyDate
function FeyDate:get_adjusted_date()
  if not self:is_deadline() and not self:is_scheduled() then
    return self
  end

  local adj = self:get_negative_adjustment()

  if self:is_deadline() then
    local warning_amount = config.fey_deadline_warning_days
    local span = 'day'
    if adj then
      warning_amount = adj.amount
      span = adj.span
    end
    return self:subtract({ [span] = warning_amount })
  end

  if not adj then
    return self
  end
  return self:add({ [adj.span] = adj.amount })
end

---@return string
function FeyDate:get_week_number()
  return self:format('%V')
end

return FeyDate
