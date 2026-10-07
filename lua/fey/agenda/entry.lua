-- A heading of the agenda: what the agenda views need to know about a heading, read from a row of the
-- vault instead of the syntax tree. It answers the questions the views ask of a heading (`get_todo`,
-- `is_done`, `get_priority`, `get_category`, `get_title`, `get_labels`, ...), so sorting, filtering and
-- rendering do not care where it comes from.
--
-- An entry also knows where it lives, for the actions on it (II.L): the hollow, the file (`path` relative
-- to the hollow, `abs` absolute), the `line` of the heading and its `signature`.
local config = require('fey.config')
local utils = require('fey.utils')

---@class FeyAgendaEntry
---@field hollow string canonical id of the hollow
---@field root string root of the hollow
---@field path string file, relative to the hollow
---@field abs string
---@field line integer line of the heading (1 based)
---@field ord integer index of the heading in its file
---@field signature? string
---@field title string
---@field state? string todo keyword
---@field priority? string
---@field labels string[]
---@field level? integer
---@field end_line? integer
---@field props table<string, any>
---@field file { index: integer, get_category: fun(): string }
local Entry = {}
Entry.__index = Entry

---@param row table a row of `FeyVault:dates` or `FeyVault:tasks`, with `hollow` and `abs`
---@param index? integer position of the file among the files of the agenda
---@return FeyAgendaEntry
function Entry.from_row(row, index)
  local self = setmetatable({
    hollow = row.hollow,
    root = row.root,
    path = row.path,
    abs = row.abs,
    line = row.heading_line or row.line,
    ord = row.heading_ord,
    signature = row.signature,
    title = row.heading_title or row.title or '',
    state = row.state,
    priority = row.priority,
    labels = row.labels or {},
    props = row.props or {},
    level = row.level,
    end_line = row.end_line,
    _plan = row.plan,
    _category = row.category,
  }, Entry)
  self.file = {
    index = index or 1,
    get_category = function() return self:file_category() end,
  }
  return self
end

---The category of the document, else its file name without extension
---@return string
function Entry:file_category()
  if type(self._category) == 'string' and self._category ~= '' then return self._category end
  return vim.fn.fnamemodify(self.path, ':t:r')
end

---Identity of the heading across the hollows
---@return string
function Entry:key() return table.concat({ self.hollow or '', self.path or '', tostring(self.ord) }, '\0') end

---@return string|nil keyword, nil node, string|nil type, integer|nil index
function Entry:get_todo()
  if not self.state then return nil, nil, nil, nil end
  local keyword = config:get_todo_keywords():find(self.state)
  if not keyword then return nil, nil, nil, nil end
  return self.state, nil, keyword.type, keyword.index
end

---@return boolean
function Entry:is_done()
  local _, _, type = self:get_todo()
  return type == 'DONE'
end

---@return boolean
function Entry:is_todo()
  local _, _, type = self:get_todo()
  return type == 'TODO'
end

---@return string priority '' when there is none
---@return table|nil node
function Entry:get_priority() return self.priority or '', nil end

---@return number
function Entry:get_priority_sort_value()
  local PriorityState = require('fey.objects.priority_state')
  return PriorityState:new(self:get_priority(), config:get_priority_range()):get_sort_value()
end

---@return string title, integer offset
function Entry:get_title() return self.title, 0 end

---The `category` prop of the heading, else the category of the document
---@return string
function Entry:get_category()
  local prop = self.props.category
  if type(prop) == 'table' then prop = prop[1] end
  if prop ~= nil and tostring(prop) ~= '' then return tostring(prop) end
  return self:file_category()
end

---@param category string
---@return boolean
function Entry:matches_category(category) return self:get_category() == category end

---@return string[] labels
function Entry:get_labels() return self.labels, nil end

---@param tag string
---@return boolean
function Entry:has_label(tag)
  for _, label in ipairs(self.labels) do
    if label == tag then return true end
  end
  return false
end

---@param sorted? boolean
---@return string
function Entry:labels_to_string(sorted) return utils.labels_to_string(self.labels, sorted) end

---@return boolean
function Entry:is_archived()
  if self.path and self.path:match('%.fey_archive$') then return true end
  for _, label in ipairs(self.labels) do
    if label:upper() == 'ARCHIVE' then return true end
  end
  return false
end

---@param kind 'deadline'|'scheduled'|'closed'
---@return FeyDate|nil
function Entry:_plan_date(kind)
  local row = self._plan and self._plan[kind]
  if not row then return nil end
  self._planning_dates = self._planning_dates or {}
  if self._planning_dates[kind] == nil then
    self._planning_dates[kind] = require('fey.agenda.source').dates_of(row)[1] or false
  end
  return self._planning_dates[kind] or nil
end

---@return FeyDate|nil
function Entry:get_deadline_date() return self:_plan_date('deadline') end

---@return FeyDate|nil
function Entry:get_scheduled_date() return self:_plan_date('scheduled') end

---@return FeyDate|nil
function Entry:get_closed_date() return self:_plan_date('closed') end

---What the match language (`+work-home/TODO`, `priority="A"`, `deadline<"<today>"`) looks at
---@return FeySearchable
function Entry:search_item()
  local props = {}
  for key, value in pairs(self.props) do
    if type(value) == 'table' then value = value[1] end
    props[key:lower()] = tostring(value)
  end
  local deadline, scheduled, closed = self:get_deadline_date(), self:get_scheduled_date(), self:get_closed_date()
  local todo = self:get_todo() or ''
  return {
    props = vim.tbl_extend('keep', props, {
      category = self:get_category(),
      deadline = deadline and deadline:to_wrapped_string(true),
      scheduled = scheduled and scheduled:to_wrapped_string(true),
      closed = closed and closed:to_wrapped_string(false),
      priority = self.priority or '',
      todo = todo,
      level = self.level,
    }),
    tags = self.labels,
    todo = todo,
  }
end

---The lines of the heading and everything below it (from the buffer when it is loaded)
---@return string[]
function Entry:get_lines()
  local buf = vim.fn.bufnr(self.abs)
  local lines
  if buf > 0 and vim.api.nvim_buf_is_loaded(buf) then
    lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  elseif self.abs and vim.fn.filereadable(self.abs) == 1 then
    lines = vim.fn.readfile(self.abs)
  else
    return { self.title }
  end
  local last = math.min(self.end_line or #lines, #lines)
  return vim.list_slice(lines, self.line, last)
end

---Does a clock run on this heading (set when the source builds the entry)
---@return boolean
function Entry:is_clocked_in() return self._clocked == true end

-- the old names, kept for a release (III.R)
do
  local alias = require('fey.utils.deprecate').alias
  alias(Entry, 'get_tags', 'get_labels', 'Entry:get_tags')
  alias(Entry, 'has_tag', 'has_label', 'Entry:has_tag')
  alias(Entry, 'tags_to_string', 'labels_to_string', 'Entry:tags_to_string')
end

return Entry
