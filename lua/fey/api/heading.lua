local FeyPosition = require('fey.api.position')
local config = require('fey.config')
local PriorityState = require('fey.objects.priority_state')
local Date = require('fey.objects.date')
local Calendar = require('fey.objects.calendar')
local Promise = require('fey.utils.promise')
local fey = require('fey')
local Buffers = require('fey.state.buffers')

---@class FeyApiHeading
---@field title string heading title without todo keyword, tags and priority. Ex. `* TODO I am a heading  :SOMETAG:` returns `I am a heading`
---@field line string full heading line
---@field level number heading level (number of asterisks). Example: 1
---@field todo_value? string todo keyword of the heading (Example: TODO, DONE)
---@field todo_type? 'TODO' | 'DONE' | ''
---@field tags string[] List of own tags
---@field deadline FeyDate|nil
---@field scheduled FeyDate|nil
---@field properties table<string, string> Table containing all properties. All keys are lowercased
---@field closed FeyDate|nil
---@field dates FeyDate[] List of all dates that are not "plan" dates
---@field position FeyRange
---@field all_tags string[] List of all tags (own + inherited)
---@field file FeyApiFile
---@field parent FeyApiHeading|nil
---@field priority string|nil
---@field is_archived boolean heading marked with the `:ARCHIVE:` tag
---@field headings FeyApiHeading[]
---@field private _section FeyHeading
---@field private _index number
local FeyHeading = {}

---@private
function FeyHeading:_new(opts)
  local data = {}
  data.file = opts.file
  data.todo_type = opts.todo_type
  data.todo_value = opts.todo_value
  data.title = opts.title
  data.line = opts.line
  data.level = opts.level
  data.category = opts.category
  data.position = opts.position
  data.tags = opts.tags
  data.all_tags = opts.all_tags
  data.priority = opts.priority
  data.deadline = opts.deadline
  data.properties = opts.properties
  data.scheduled = opts.scheduled
  data.closed = opts.closed
  data.dates = opts.dates
  data.is_archived = opts.is_archived
  data.parent = opts.parent
  data.headings = opts.headings or {}
  data._section = opts._section
  data._index = opts._index

  setmetatable(data, self)
  self.__index = self
  return data
end

---@param section FeyHeading
---@param index number
---@private
function FeyHeading._build_from_internal_heading(section, index)
  local todo, _, type = section:get_todo()
  local properties = section:get_own_properties()
  return FeyHeading:_new({
    title = section:get_title(),
    line = section:get_heading_line_content(),
    level = section:get_level(),
    todo_type = type,
    todo_value = todo,
    all_tags = section:get_tags(),
    tags = section:get_own_tags(),
    ---@diagnostic disable-next-line: invisible
    position = FeyPosition:_build_from_internal_range(section:get_range()),
    properties = properties,
    deadline = section:get_deadline_date(),
    scheduled = section:get_scheduled_date(),
    closed = section:get_closed_date(),
    dates = vim.tbl_filter(function(date)
      return date:is_none()
    end, section:get_all_dates()),
    priority = section:get_priority(),
    is_archived = section:is_archived(),
    _section = section,
    _index = index,
  })
end

--- Return updated version of heading
---@return FeyApiHeading
function FeyHeading:reload()
  local file = self.file:reload()
  return file.headings[self._index]
end

--- Set tags on the heading. This replaces all current tags with provided ones
---@param tags string[]
---@return FeyPromise
function FeyHeading:set_tags(tags)
  return self:_do_action(function()
    local heading = fey.files:get_closest_heading()
    heading:set_tags(string.format(':%s:', table.concat(tags, ':')))
  end)
end

--- Increase priority on a heading
---@return FeyPromise
function FeyHeading:priority_up()
  return self:_do_action(function()
    local heading = fey.files:get_closest_heading()
    local current_priority = heading:get_priority()
    local prio_range = config:get_priority_range()
    local start_with_default = config.fey_priority_start_cycle_with_default
    local priority_state = PriorityState:new(current_priority, prio_range, start_with_default)
    return heading:set_priority(priority_state:increase())
  end)
end

--- Decrease priority on a heading
---@return FeyPromise
function FeyHeading:priority_down()
  return self:_do_action(function()
    local heading = fey.files:get_closest_heading()
    local current_priority = heading:get_priority()
    local prio_range = config:get_priority_range()
    local start_with_default = config.fey_priority_start_cycle_with_default
    local priority_state = PriorityState:new(current_priority, prio_range, start_with_default)
    return heading:set_priority(priority_state:decrease())
  end)
end

--- Set specific priority on a heading. Empty string clears the priority
---@param priority string
---@return FeyPromise
function FeyHeading:set_priority(priority)
  return self:_do_action(function()
    local heading = fey.files:get_closest_heading()
    return heading:set_priority(priority)
  end)
end

--- Set deadline date
---@param date? FeyDate|string|nil If ommited, opens the datepicker. Empty string removes the date. String must follow fey date convention (YYYY-MM-DD HH:mm...)
---@return FeyPromise
function FeyHeading:set_deadline(date)
  return self:_do_action(function()
    local heading = fey.files:get_closest_heading()
    local deadline_date = heading:get_deadline_date()
    if not date then
      return Calendar.new({ date = deadline_date or Date.today(), clearable = true, title = 'Set deadline' })
        :open()
        :next(function(new_date, cleared)
          if cleared then
            return heading:remove_deadline_date()
          end
          if not new_date then
            return
          end
          return heading:set_deadline_date(new_date)
        end)
    end

    if type(date) == 'string' then
      if date == '' then
        return heading:remove_deadline_date()
      end
      local date_instance = Date.from_string(date)
      if date_instance then
        return heading:set_deadline_date(date_instance)
      end
      error('Invalid string format for deadline date', 0)
    end

    if Date.is_date_instance(date) then
      return heading:set_deadline_date(date)
    end

    error('Invalid argument to set_deadline', 0)
  end)
end

--- Set scheduled date
---@param date? FeyDate|string|nil If ommited, opens the datepicker. Empty string removes the date. String must follow fey date convention (YYYY-MM-DD HH:mm...)
---@return FeyPromise
function FeyHeading:set_scheduled(date)
  return self:_do_action(function()
    local heading = fey.files:get_closest_heading()
    local scheduled_date = heading:get_scheduled_date()
    if not date then
      return Calendar.new({ date = scheduled_date or Date.today(), clearable = true, title = 'Set schedule' })
        :open()
        :next(function(new_date, cleared)
          if cleared then
            return heading:remove_scheduled_date()
          end
          if not new_date then
            return
          end
          return heading:set_scheduled_date(new_date)
        end)
    end

    if type(date) == 'string' then
      if date == '' then
        return heading:remove_scheduled_date()
      end
      local date_instance = Date.from_string(date)
      if date_instance then
        return heading:set_scheduled_date(date_instance)
      end
      error('Invalid string format for schedule date', 0)
    end

    if Date.is_date_instance(date) then
      return heading:set_scheduled_date(date)
    end

    error('Invalid argument to set_scheduled', 0)
  end)
end

--- Set property on a heading. Setting value to nil removes the property
---@param key string
---@param value? string
function FeyHeading:set_property(key, value)
  return self:_do_action(function()
    local heading = fey.files:get_closest_heading()
    return heading:set_property(key, value)
  end)
end

--- Get heading property
---@param key string
---@return string | nil
function FeyHeading:get_property(key)
  return self.properties[key:lower()]
end

--- Get heading id or create a new one if it doesn't exist
--- @return string
function FeyHeading:id_get_or_create()
  local id = self:get_property('id')
  if id then
    return id
  end
  local fey_id = require('fey.fey.id').new()
  self:set_property('ID', fey_id)
  return fey_id
end

---@param action function
---@private
function FeyHeading:_do_action(action)
  return fey.files:update_file(self.file.filename, function()
    local view = vim.fn.winsaveview() or {}
    vim.fn.cursor({ self.position.start_line, 1 })
    return Promise.resolve(action()):next(function()
      vim.fn.winrestview(view)
      return self:reload()
    end)
  end)
end

--- Get a link destination as string
---
--- Depending if fey_id_link_to_fey_use_id is set the format is
---
--- id:<uuid>::*title and the id is created if not existing
--- or
--- file:<filepath>::*title
---
--- The result is meant to be used as link_location for FeyApi.insert_link.
--- @return string
function FeyHeading:get_link()
  local filename = self.file.filename
  local bufnr = Buffers.get_buffer_by_filename(filename)

  if bufnr == -1 or not vim.api.nvim_buf_is_loaded(bufnr) then
    -- do remote edit
    return fey.files
      :update_file(filename, function(_)
        return fey.links:get_link_to_heading(self._section)
      end)
      :wait()
  end

  return fey.links:get_link_to_heading(self._section)
end

return FeyHeading
