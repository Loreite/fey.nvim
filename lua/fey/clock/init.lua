local Duration = require('fey.objects.duration')
local utils = require('fey.utils')
local Promise = require('fey.utils.promise')
local Input = require('fey.ui.input')

---@class FeyClock
---@field files FeyFiles
---@field clocked_heading FeyHeading|nil
local Clock = {}

function Clock:new(opts)
  local data = {
    files = opts.files,
    clocked_heading = nil,
  }
  setmetatable(data, self)
  self.__index = self
  data:init()
  return data
end

-- When first loading, check if there are active clocks
function Clock:init()
  local last_clocked_heading = self.files:get_clocked_heading()
  if last_clocked_heading and last_clocked_heading:is_clocked_in() then
    self.clocked_heading = last_clocked_heading
  end
end

function Clock:update_clocked_heading()
  local last_clocked_heading = self.files:get_clocked_heading()
  if last_clocked_heading and last_clocked_heading:is_clocked_in() then
    self.clocked_heading = last_clocked_heading
  end
end

function Clock:has_clocked_heading()
  self:update_clocked_heading()
  return self.clocked_heading ~= nil
end

function Clock:fey_clock_in()
  self:update_clocked_heading()
  local item = self.files:get_closest_heading()
  if item:is_clocked_in() then
    return utils.echo_info(string.format('Clock continues in "%s"', item:get_title()))
  end

  local promise = Promise.resolve()

  if self.clocked_heading and self.clocked_heading:is_clocked_in() then
    local file = self.clocked_heading.file
    promise = file:update(function()
      local clocked_item = file:reload_sync():get_closest_heading({ self.clocked_heading:get_range().start_line, 0 })
      clocked_item:clock_out()
    end)
  end

  return promise:next(function()
    item:clock_in()
    self.clocked_heading = item
  end)
end

function Clock:fey_clock_out()
  self:update_clocked_heading()
  if not self.clocked_heading or not self.clocked_heading:is_clocked_in() then
    return
  end

  self.clocked_heading:clock_out()
  self.clocked_heading = nil
end

function Clock:fey_clock_cancel()
  self:update_clocked_heading()
  if not self.clocked_heading or not self.clocked_heading:is_clocked_in() then
    return utils.echo_info('No active clock')
  end

  self.clocked_heading:cancel_active_clock()
  self.clocked_heading = nil
  utils.echo_info('Clock canceled')
end

function Clock:fey_clock_goto()
  self:update_clocked_heading()
  if not self.clocked_heading then
    return utils.echo_info('No active or recent clock task')
  end

  if not self.clocked_heading:is_clocked_in() then
    utils.echo_info('No running clock, this is the most recently clocked task')
  end

  utils.goto_heading(self.clocked_heading)
end

function Clock:fey_set_effort()
  local item = self.files:get_closest_heading()
  -- TODO: Add Effort_ALL property as autocompletion
  local current_effort = item:get_property('Effort')
  return Input.open('Effort: ', current_effort or ''):next(function(effort)
    if not effort then
      return false
    end
    local duration = Duration.parse(effort)
    if duration == nil then
      return utils.echo_error('Invalid duration format: ' .. effort)
    end
    item:set_property('Effort', effort)
    return item
  end)
end

function Clock:get_statusline()
  if not self.clocked_heading or not self.clocked_heading:is_clocked_in() then
    return ''
  end

  local effort = self.clocked_heading:get_property('effort', false)
  local total = self.clocked_heading:get_logbook():get_total_with_active():to_string()
  if effort then
    return string.format('(Fey) [%s/%s] (%s)', total, effort or '', self.clocked_heading:get_title())
  end
  return string.format('(Fey) [%s] (%s)', total, self.clocked_heading:get_title())
end

return Clock
