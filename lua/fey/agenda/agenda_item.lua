local Highlights = require('fey.colors.highlights')
local hl_map = Highlights.get_agenda_hl_map()
local config = require('fey.config')
local FUTURE_DEADLINE_AS_WARNING_DAYS = math.floor(config.fey_deadline_warning_days / 2)
local function add_padding(datetime)
  if datetime:len() >= 10 then
    return datetime .. ' '
  end
  return datetime .. ' ' .. config.fey_agenda_time_grid.time_separator .. ' '
end

---@class FeyAgendaItem
---@field date FeyDate
---@field heading_date FeyDate
---@field real_date FeyDate
---@field heading FeyHeading
---@field is_valid boolean
---@field is_today boolean
---@field is_same_day boolean
---@field is_in_date_range boolean
---@field date_range_days number
---@field label string
---@field index number
local AgendaItem = {}

---@param heading_date FeyDate single date in a heading
---@param heading FeyHeading
---@param date FeyDate date for which item should be rendered
---@param index? number
---@return FeyAgendaItem
function AgendaItem:new(heading_date, heading, date, index)
  local opts = {}
  opts.heading_date = heading_date
  opts.real_date = heading_date
  opts.heading = heading
  opts.date = date
  opts.index = index or 1
  opts.is_valid = false
  opts.is_today = date:is_today()
  opts.repeats_on_date = false
  opts.is_same_day = heading_date:is_same(date, 'day')
  if not opts.is_same_day then
    local repeat_count = config:get_repeat_count()
    opts.repeats_on_date = heading_date:repeats_on(date, repeat_count)
    opts.is_same_day = opts.repeats_on_date
  end
  opts.is_in_date_range = heading_date:is_none() and heading_date:is_in_date_range(date)
  opts.date_range_days = heading_date:get_date_range_days()
  opts.label = ''
  if opts.repeats_on_date then
    opts.real_date = opts.heading_date:apply_repeater_until(opts.date)
  end
  setmetatable(opts, self)
  self.__index = self
  opts:_process()
  return opts
end

---@param heading FeyHeading
function AgendaItem:set_heading(heading)
  self.heading = heading
  if self.is_valid then
    self:_generate_data()
  end
end

function AgendaItem:_process()
  if self.is_today then
    self.is_valid = self:_is_valid_for_today()
  else
    self.is_valid = self:_is_valid_for_date()
  end

  if self.is_valid then
    self:_generate_data()
  end
end

function AgendaItem:_generate_data()
  self.label = self:_generate_label()
end

function AgendaItem:_is_valid_for_today()
  if not self.heading_date.active or self.heading_date:is_closed() or self.heading_date:is_obsolete_range_end() then
    return false
  end
  if self.heading_date:is_none() then
    return self.is_same_day or self.is_in_date_range
  end

  if self.heading_date:is_deadline() then
    if self.heading:is_done() and config.fey_agenda_skip_deadline_if_done then
      return false
    end
    if self.heading_date.is_date_range_end then
      return false
    end
    if self.is_same_day then
      return true
    end
    if self.heading_date:is_before(self.date, 'day') then
      return not self.heading:is_done()
    end
    return not self.heading:is_done()
      and self.date:is_between(self.heading_date:get_adjusted_date(), self.heading_date, 'day')
  end

  if self.heading:is_done() and config.fey_agenda_skip_scheduled_if_done then
    return false
  end

  if not self.heading_date:get_negative_adjustment() then
    if self.is_same_day then
      return true
    end
    if self.heading_date:is_before(self.date, 'day') and not self.heading:is_done() then
      return true
    end
    return false
  end

  if self.heading_date:get_adjusted_date():is_same_or_before(self.date, 'day') and not self.heading:is_done() then
    return true
  end

  return false
end

function AgendaItem:_is_valid_for_date()
  if not self.heading_date.active or self.heading_date:is_closed() or self.heading_date:is_obsolete_range_end() then
    return false
  end

  if self.heading:is_done() then
    if self.heading_date:is_deadline() and config.fey_agenda_skip_deadline_if_done then
      return false
    end
    if self.heading_date:is_scheduled() and config.fey_agenda_skip_scheduled_if_done then
      return false
    end
  end

  if
    (self.heading_date:is_deadline() or self.heading_date:is_scheduled()) and self.heading_date.is_date_range_end
  then
    return false
  end

  if not self.heading_date:is_scheduled() or not self.heading_date:get_negative_adjustment() then
    return self.is_same_day or self.is_in_date_range
  end

  return false
end

function AgendaItem:_generate_label()
  local time = self.heading_date:has_time() and add_padding(self:_format_time(self.heading_date)) or ''
  if self.heading_date:is_deadline() then
    if self.is_same_day then
      return time .. 'Deadline:'
    end
    return self.heading_date:humanize(self.date) .. ':'
  end

  if self.heading_date:is_scheduled() then
    if self.is_same_day then
      return time .. 'Scheduled:'
    end

    local diff = math.abs(self.date:diff(self.heading_date))

    return 'Sched. ' .. diff .. 'x:'
  end

  if self.heading_date.is_date_range_start then
    if not self.is_in_date_range then
      return time
    end
    local range = string.format('(%d/%d):', self.date:diff(self.heading_date) + 1, self.date_range_days)
    if not self.is_same_day then
      return range
    end
    return time .. range
  end

  if self.heading_date.is_date_range_end then
    local range = string.format('(%d/%d):', self.date_range_days, self.date_range_days)
    return time .. range
  end

  return time
end

---@private
---@param date FeyDate
function AgendaItem:_format_time(date)
  local formatted_time = date:format_time()

  -- e.g. <2024-09-24 Sun 10:00-11:00>
  if date:has_time_range() then
    return formatted_time
  end

  local date_range_end = date:get_date_range_end()

  -- Format same day date ranges as a time range if the date itself
  -- does not have a time range (e.g. <2023-09-24 Sun 10:00-11:00)
  -- example: <2023-09-24 Sun 10:00>--<2023-09-24 Sun 11:00>
  -- result: 10:00-11:00
  if date_range_end and date_range_end:is_same(date, 'day') and date_range_end:has_time() then
    return formatted_time .. '-' .. date_range_end:format_time()
  end

  return formatted_time
end

---@return string | nil
function AgendaItem:get_hlgroup()
  if self.heading_date:is_deadline() then
    if self.heading:is_done() then
      return hl_map.ok
    end
    if self.is_today and self.heading_date:is_after(self.date, 'day') then
      local diff = math.abs(self.date:diff(self.heading_date))
      if diff <= FUTURE_DEADLINE_AS_WARNING_DAYS then
        return hl_map.upcoming_deadline
      end
      return nil
    end

    return hl_map.deadline
  end

  if self.heading_date:is_scheduled() then
    if self.heading_date:is_past('day') and not self.heading:is_done() then
      return hl_map.warning
    end

    return hl_map.ok
  end

  return nil
end

function AgendaItem:get_todo_hlgroup()
  local todo_keyword, _, type = self.heading:get_todo()
  if not todo_keyword then
    return
  end
  return hl_map[todo_keyword] or hl_map[type], todo_keyword
end

function AgendaItem:get_priority_hlgroup()
  local priority, priority_node = self.heading:get_priority()
  if not priority_node then
    return
  end
  return hl_map.priority[priority].hl_group, priority
end

return AgendaItem
