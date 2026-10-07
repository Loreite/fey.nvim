-- The logbook of a heading: a pair tag with one clock tag per period of work.
--
--   [ logbook #]
--   {# clock, 2026-10-06 Tue 10:00; end: 2026-10-06 Tue 11:30; dur: 1:30 #}
--   {# clock, 2026-10-06 Tue 13:00 #}
--   [# logbook ]
--
-- A clock without an `end` is running. Newest first. The tags are text of the heading's own section (not its
-- subsections). Everything here works on the buffer the heading is in, so it runs in a window of that buffer.
local Date = require('fey.objects.date')
local Duration = require('fey.objects.duration')
local config = require('fey.config')

---@class FeyLogbookItem
---@field line integer 1-based line of the clock tag
---@field start_time FeyDate
---@field end_time? FeyDate
---@field duration? FeyDuration

---@class FeyLogbook
---@field heading FeyHeading
---@field bufnr integer
---@field range? { start_line: integer, end_line: integer } the opener and the closer, 1-based
---@field items FeyLogbookItem[]
local Logbook = {}
Logbook.__index = Logbook

---Where the own text of a heading is (up to its first subsection), 1-based
---@param heading FeyHeading
---@return integer first the heading line
---@return integer last
local function own_range(heading)
  local section = heading:node():parent()
  local first, _, er, ec = section:range()
  local child = section:field('subsection')[1]
  if child then return first + 1, (child:start()) end
  return first + 1, ec == 0 and er or er + 1
end

local function open_pattern() return '^%s*%[%s*' .. vim.pesc(config.fey_logbook_tag_name) .. '%s*#%]' end
local function close_pattern() return '^%s*%[#%s*' .. vim.pesc(config.fey_logbook_tag_name) .. '%s*%]' end
local function clock_pattern() return '^%s*{#%s*' .. vim.pesc(config.fey_clock_tag_name) .. '%s*,' end

---The value of the clock tag on a line: its start text and the text of its `end` key
---@param line string
---@return string|nil start_text
---@return string|nil end_text
local function parse_clock_line(line)
  if not line:match(clock_pattern()) then return nil end
  local body = line:match('^%s*{#%s*[^,]*,(.-)%s*#}%s*$')
  if not body then return nil end
  local head, keys = body, ''
  local semi = body:find(';', 1, true)
  if semi then head, keys = body:sub(1, semi - 1), body:sub(semi + 1) end
  local end_text = keys:match('end:%s*([^;]-)%s*$') or keys:match('end:%s*([^;]-)%s*;')
  return vim.trim(head), end_text and vim.trim(end_text) or nil
end

---@param text string
---@return FeyDate|nil
local function date_of(text) return Date.from_parts('date', { text }, { active = 'false' })[1] end

---The logbook of a heading, nil when it has none
---@param heading FeyHeading
---@return FeyLogbook|nil
function Logbook.from_heading(heading)
  local bufnr = heading.file:get_valid_bufnr()
  local first, last = own_range(heading)
  local lines = vim.api.nvim_buf_get_lines(bufnr, first - 1, last, false)
  local open, close
  for i, l in ipairs(lines) do
    if not open and l:match(open_pattern()) then open = i
    elseif open and not close and l:match(close_pattern()) then close = i end
  end
  if not open then return nil end
  close = close or #lines
  local items = {}
  for i = open + 1, close - 1 do
    local start_text, end_text = parse_clock_line(lines[i])
    local started = start_text and date_of(start_text)
    if started then
      local ended = end_text and date_of(end_text) or nil
      items[#items + 1] = {
        line = first + i - 1,
        start_time = started,
        end_time = ended,
        duration = ended and Duration.from_seconds(ended.timestamp - started.timestamp) or nil,
      }
    end
  end
  return setmetatable({
    heading = heading,
    bufnr = bufnr,
    range = { start_line = first + open - 1, end_line = first + close - 1 },
    items = items,
  }, Logbook)
end

---@return boolean
function Logbook:is_active() return self:get_active() ~= nil end

---The running clock
---@return FeyLogbookItem|nil
function Logbook:get_active()
  for _, item in ipairs(self.items) do
    if not item.end_time then return item end
  end
end

---Minutes in the clocks that start or end between two dates (all of them without a range)
---@param from? FeyDate
---@param to? FeyDate
---@return number
function Logbook:get_total_minutes(from, to)
  local total = 0
  for _, item in ipairs(self.items) do
    if item.duration then
      if not (from and to) or item.start_time:is_between(from, to) or item.end_time:is_between(from, to) then
        total = total + item.duration.minutes
      end
    end
  end
  return total
end

---@param from? FeyDate
---@param to? FeyDate
---@return FeyDuration
function Logbook:get_total(from, to) return Duration.from_minutes(self:get_total_minutes(from, to)) end

---The total, with the time the running clock has run so far
---@return FeyDuration
function Logbook:get_total_with_active()
  local total = self:get_total()
  local active = self:get_active()
  if not active then return total end
  return Duration.from_minutes(total.minutes + Duration.from_seconds(Date.now().timestamp - active.start_time.timestamp).minutes)
end

---The text of a clock tag
---@param start_text string
---@param end_text? string
---@param dur_text? string
---@return string
local function clock_text(start_text, end_text, dur_text)
  local keys = {}
  if end_text then keys['end'] = end_text end
  if dur_text then keys.dur = dur_text end
  return require('fey.files.elements.tags.edit').build(config.fey_clock_tag_name, { start_text }, keys, { order = { 'end', 'dur' } })
end

---Start a clock now in a heading: into its logbook, or into a new one under its metadata
---@param heading FeyHeading
---@return FeyDate started
function Logbook.add_clock_in(heading)
  local now = Date.now({ active = false })
  local text = clock_text(now:to_tag_value())
  local logbook = Logbook.from_heading(heading)
  if logbook then
    vim.api.nvim_buf_set_lines(logbook.bufnr, logbook.range.start_line, logbook.range.start_line, false, { text })
    return now
  end
  local bufnr = heading.file:get_valid_bufnr()
  local at = heading:get_append_line()
  local block = { ('[ %s #]'):format(config.fey_logbook_tag_name), text, ('[# %s ]'):format(config.fey_logbook_tag_name) }
  local following = vim.api.nvim_buf_get_lines(bufnr, at, at + 1, false)[1]
  if following and following:match('%S') then block[#block + 1] = '' end
  vim.api.nvim_buf_set_lines(bufnr, at, at, false, block)
  return now
end

---Stop the running clock of a heading, writing the end and the time it ran
---@param heading FeyHeading
---@return FeyDuration|nil duration nil when nothing was running
---@return FeyDate|nil ended
function Logbook.clock_out(heading)
  local logbook = Logbook.from_heading(heading)
  local active = logbook and logbook:get_active()
  if not active then return nil end
  local now = Date.now({ active = false })
  local duration = Duration.from_seconds(now.timestamp - active.start_time.timestamp)
  local text = clock_text(active.start_time:to_tag_value(), now:to_tag_value(), duration:to_string('HH:MM'))
  vim.api.nvim_buf_set_lines(logbook.bufnr, active.line - 1, active.line, false, { text })
  return duration, now
end

---Throw away the running clock; the logbook goes with it when it holds nothing else
---@param heading FeyHeading
---@return boolean removed
function Logbook.cancel_active_clock(heading)
  local logbook = Logbook.from_heading(heading)
  local active = logbook and logbook:get_active()
  if not active then return false end
  local bufnr = logbook.bufnr
  if #logbook.items == 1 then
    -- only the block: a blank line next to it was there before the logbook or is harmless
    vim.api.nvim_buf_set_lines(bufnr, logbook.range.start_line - 1, logbook.range.end_line, false, {})
  else
    vim.api.nvim_buf_set_lines(bufnr, active.line - 1, active.line, false, {})
  end
  return true
end

---Write the time a clock tag ran after its start or end was edited by hand
---@param bufnr integer
---@param linenr integer
---@return boolean changed
function Logbook.recalculate_line(bufnr, linenr)
  local line = vim.api.nvim_buf_get_lines(bufnr, linenr - 1, linenr, false)[1]
  local start_text, end_text = parse_clock_line(line or '')
  local started, ended = start_text and date_of(start_text), end_text and date_of(end_text)
  if not started or not ended then return false end
  local text = clock_text(start_text, end_text, Duration.from_seconds(ended.timestamp - started.timestamp):to_string('HH:MM'))
  if text == line then return false end
  local view = vim.fn.winsaveview() or {}
  vim.api.nvim_buf_set_lines(bufnr, linenr - 1, linenr, false, { text })
  vim.fn.winrestview(view)
  return true
end

---Is a line a clock tag line
---@param line string
---@return boolean
function Logbook.is_clock_line(line) return line:match(clock_pattern()) ~= nil end

return Logbook
