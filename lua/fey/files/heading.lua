local utils = require('fey.utils')
local ts_utils = require('fey.utils.treesitter')
local Date = require('fey.objects.date')
local Range = require('fey.files.elements.range')
local config = require('fey.config')
local PriorityState = require('fey.objects.priority_state')
local indent = require('fey.fey.indent')
local Logbook = require('fey.files.elements.logbook')
local Checkbox = require('fey.files.elements.checkbox')
local FeyId = require('fey.fey.id')
local Memoize = require('fey.utils.memoize')
local EventManager = require('fey.events')
local events = EventManager.event
local sequences = require('fey.utils.sequences')
local edit = require('fey.files.elements.tags.edit')

---@alias FeyPlanningDateTypes 'DEADLINE' | 'SCHEDULED' | 'CLOSED'

---@class FeyHeading
---@field heading TSNode
---@field file FeyFile
---@field index? number
local Heading = {}

local memoize = Memoize:new(Heading, function(self)
  ---@cast self FeyHeading
  return {
    file = self.file,
    id = table.concat({ 'heading', self.heading:id() }, '_'),
  }
end)

---@param heading_node TSNode tree sitter heading node
---@param file FeyFile
function Heading:new(heading_node, file)
  local data = {
    heading = heading_node,
    file = file,
  }
  setmetatable(data, self)
  return data
end

---Names of the metadata tags (the `vault.meta_tags` option), left out of the title of a heading
---@return table<string, boolean>
local function meta_tag_set()
  local set = {}
  for _, name in ipairs(config.vault.meta_tags or {}) do
    set[name] = true
  end
  return set
end

---Names of the tags that hold labels
---@return string[]
local function label_names()
  local names = { config.fey_labels_tag_name }
  for _, name in ipairs(config.vault.label_tags or {}) do
    if not vim.tbl_contains(names, name) then table.insert(names, name) end
  end
  return names
end

---The first tag of the title when it has the given name: the status tag must come first
---@param self FeyHeading
---@param name string
---@param source? integer|string
---@return FeyTag|nil
local function first_title_tag(self, name, source)
  local title = self:node():field('title')[1]
  local first = title and title:child(0)
  if not first or first:type() ~= 'scope_tag' or first:has_error() then return nil end
  local tag = require('fey.files.elements.tags').parse_tag_node(source or self.file:get_source(), first)
  return tag.name == name and tag or nil
end

---Property names are tag keys: lower case, letters digits and `_` (`header-args` is `header_args`)
---@param name string
---@return string
local function prop_key(name) return (name:lower():gsub('[^%w_]', '_')) end

---@param s string
local function unescape(s) return (s:gsub('\\(.)', '%1')) end

---Return up to date heading node
---@return TSNode
function Heading:node()
  local bufnr = self.file:bufnr()
  if bufnr < 0 then return self.heading end
  return self:refresh().heading
end

--- Refresh the heading
--- @return FeyHeading
function Heading:refresh()
  local start_row, start_col = self.heading:start()
  local updated_heading = self.file:closest_heading_node({ start_row + 1, start_col })
  if updated_heading then self.heading = updated_heading end
  return self
end

memoize('get_level')
---@return number
function Heading:get_level()
  local count = self:get_child_node('signature'):named_child_count()
  return count
end

memoize('get_signature_width')
---@return number
function Heading:get_signature_width()
  local _, count = self:get_child_node('signature'):end_()
  return count
end

memoize('get_priority')
---The priority of the heading: the second plain value of its status tag, or its `priority` key when the
---tag has no keyword. Only a value that is a priority of the config counts.
---@return string, TSNode | nil
function Heading:get_priority()
  local tag = first_title_tag(self, config.fey_status_tag_name)
  local priority = tag and (tag.values[2] or tag.key_values.priority)
  if priority and config:get_priorities()[priority] then return priority, tag.node end
  return '', nil
end

---@param amount number
---@param recursive? boolean
---@param dryRun? boolean
---@return string[]
function Heading:promote(amount, recursive, dryRun)
  amount = math.min(amount or 1, self:get_level() - 1)
  recursive = recursive or false
  if self:get_level() == 1 then
    utils.echo_warning('Cannot promote top level heading.')
    return {}
  end

  return self:_handle_promote_demote(recursive, function(start_line, lines, heading)
    local signature_node = heading:get_child_node('signature')
    local total_segments = signature_node:named_child_count()

    local target_segment = signature_node:named_children()[total_segments - amount + 1]
    local _, sig_start, _, sig_end = signature_node:range()
    local _, target_start = target_segment:start()
    local indent_width = sig_end - target_start

    local signature_text = vim.treesitter.get_node_text(signature_node, heading.file:bufnr())
    local new_signature = signature_text:sub(1, target_start - sig_start)

    lines[1] = lines[1]:sub(1, sig_start) .. new_signature .. lines[1]:sub(sig_end + 1)

    for i = 2, #lines do
      local line = lines[i]
      if vim.trim(line:sub(1, indent_width)) == '' and config:should_indent(heading.file:bufnr()) then
        lines[i] = line:sub(1 + indent_width)
      else
        line, _ = line:gsub('^%s+', '')
        local is_empty = line:match('^$')
        local indent_amount = is_empty and 0 or indent.indentexpr(start_line + i, heading.file:bufnr())
        lines[i] = string.rep(' ', indent_amount) .. line
      end
    end

    return lines
  end, dryRun)
end

---@param amount number
---@param recursive? boolean
---@param dryRun? boolean
---@return string[]
function Heading:demote(amount, recursive, dryRun)
  amount = amount or 1
  recursive = recursive or false

  return self:_handle_promote_demote(recursive, function(start_line, lines, heading)
    local signature = heading:get_child_node('signature')
    local level = heading:get_level()
    local _, sig_start, _, sig_end = signature:range()

    local signature_text = vim.treesitter.get_node_text(signature, heading.file:bufnr())
    local new_segments = ''
    for i = 1, amount do
      local pattern_idx = ((level + i - 1) % #config.fey_default_subheading_index_order) + 1
      local pattern = config.fey_default_subheading_index_order[pattern_idx]
      local segment_index = sequences.patterns[pattern].to_symbol(1)
      local delim_idx = ((i - 1) % #config.fey_default_subheading_delimiter_order) + 1
      local delimiter = config.fey_default_subheading_delimiter_order:sub(delim_idx, delim_idx)
      delimiter = delimiter ~= '' and delimiter
        or vim.treesitter.get_node_text(assert(signature:named_children()[level]:child(1)), 0)

      new_segments = new_segments .. segment_index .. delimiter
    end
    local new_signature = signature_text .. new_segments

    lines[1] = lines[1]:sub(1, sig_start) .. new_signature .. lines[1]:sub(sig_end + 1)

    for i = 2, #lines do
      local line = lines[i]
      if config:should_indent(heading.file:bufnr()) then
        lines[i] = heading:_apply_indent(line, #new_segments)
      else
        line, _ = line:gsub('^%s+', '')
        local is_empty = line:match('^$')
        local indent_amount = is_empty and 0 or indent.indentexpr(start_line + i, heading.file:bufnr())
        lines[i] = string.rep(' ', indent_amount) .. line
      end
    end

    return lines
  end, dryRun)
end

---@return boolean
function Heading:is_clocked_in()
  local logbook = self:get_logbook()
  return logbook and logbook:is_active() or false
end

---Start a clock now (the logbook is made when the heading has none)
---@return FeyHeading
function Heading:clock_in()
  Logbook.add_clock_in(self)
  EventManager.dispatch(events.ClockedIn:new(self))
  return self:refresh()
end

---Stop the running clock
---@return FeyHeading
function Heading:clock_out()
  if Logbook.clock_out(self) then
    EventManager.dispatch(events.ClockedOut:new(self))
    return self:refresh()
  end
  return self
end

function Heading:cancel_active_clock()
  if Logbook.cancel_active_clock(self) then return self:refresh() end
  return self
end

---The logbook of the heading: its clocks, nil when there are none
---@return FeyLogbook | nil
function Heading:get_logbook() return Logbook.from_heading(self) end

---@return FeyDate | nil
function Heading:get_closed_date()
  local dates = self:get_planning_dates()
  return vim.tbl_get(dates, 'CLOSED', 1)
end

function Heading:get_priority_sort_value()
  local priority = self:get_priority()
  local prio_range = config:get_priority_range()
  return PriorityState:new(priority, prio_range):get_sort_value()
end

function Heading:is_archived()
  return #vim.tbl_filter(function(tag) return tag:upper() == 'ARCHIVE' end, self:get_labels()) > 0
end

---Check if heading has tag
---@param tag string
---@return boolean
function Heading:has_label(tag)
  for _, tag_item in ipairs(self:get_labels()) do
    if tag_item == tag then return true end
  end
  return false
end

memoize('get_category')
--- @return string
function Heading:get_category()
  local category = self:get_property('category', true)

  if category then return category end

  return self.file:get_category()
end

memoize('get_heading_path')
--- @return string
function Heading:get_heading_path()
  local inner_to_outer_parent_headings = {}
  local parent_section = self:node():parent():parent()

  while parent_section do
    local heading_node = parent_section:field('heading')[1]
    if heading_node then
      local heading = Heading:new(heading_node, self.file)
      local heading_title = heading:get_title()
      table.insert(inner_to_outer_parent_headings, heading_title)
    end
    parent_section = parent_section:parent()
  end

  -- reverse heading order
  local outer_to_inner_parent_headings = utils.reverse(inner_to_outer_parent_headings)
  local heading_path = table.concat(outer_to_inner_parent_headings, '/')
  return heading_path
end

---The labels of a heading are the values of its label tags (`labels` by default, see `vault.label_tags`)
---in the metadata region: the title, or the tag lines under it.

---Set the labels of the heading. The first label tag of the region is rewritten, further ones are
---removed, and with none a tag goes to the end of the title. No labels remove the tags.
---@param tags string|string[] a list, or a string separated by blanks, `,`, `;` or `:`
function Heading:set_labels(tags)
  local list = tags
  if type(tags) == 'string' then list = vim.split(vim.trim(tags), '[%s:,;]+', { trimempty = true }) end
  ---@cast list string[]

  local bufnr = self.file:get_valid_bufnr()
  local found = {}
  local names = label_names()
  for _, tag in ipairs((edit.for_heading(bufnr, self:node()))) do
    if vim.tbl_contains(names, tag.name) then table.insert(found, tag) end
  end

  -- from the last: the ranges of the ones before it stay valid
  for i = #found, (#list == 0 and 1 or 2), -1 do
    edit.remove(found[i])
  end
  if #list == 0 then return self:refresh() end

  local first = found[1]
  if first then
    local style = edit.style(first)
    local text = assert(edit.build(first.name, list, first.key_values, style))
    if first.type == 'scope_tag' then
      edit.replace(first, text)
    else
      edit.replace(first, assert(edit.build(first.name, list, first.key_values)))
    end
  else
    edit.add_to_title(bufnr, self:node(), assert(edit.build(config.fey_labels_tag_name, list)))
  end
  return self:refresh()
end

---@param tag string
---@return boolean newly_added
function Heading:add_label(tag)
  local current_tags = self:get_own_labels()
  local present = vim.tbl_contains(current_tags, tag)
  if not present then table.insert(current_tags, tag) end
  self:set_labels(current_tags)
  return not present
end

---@param tag string
---@return boolean newly_removed
function Heading:remove_tag(tag)
  local current_tags = self:get_own_labels()
  ---@type string[]
  local new_tags = vim.tbl_filter(function(i) return i ~= tag end, current_tags)
  local present = #new_tags ~= #current_tags
  if present then self:set_labels(new_tags) end
  return present
end

---@param tag string
---@return boolean newly_added
function Heading:toggle_tag(tag)
  local current_tags = self:get_own_labels()
  local present = vim.tbl_contains(current_tags, tag)
  if present then
    current_tags = vim.tbl_filter(function(i) return i ~= tag end, current_tags)
  else
    table.insert(current_tags, tag)
  end
  self:set_labels(current_tags)
  return not present
end

---Write the status tag of the title from a keyword and a priority, both optional: `{# status, TODO, A #}`,
---`{# status, TODO #}`, or `{# status; priority: A #}` without a keyword. With neither the tag is removed.
---The tag is the first thing of the title, where it stays or is added; other keys of the tag are kept.
---@private
---@param keyword? string
---@param priority? string
---@return FeyHeading
function Heading:_write_status(keyword, priority)
  local bufnr = self.file:get_valid_bufnr()
  local name = config.fey_status_tag_name
  local tag = first_title_tag(self, name, bufnr)
  keyword = keyword and vim.trim(keyword) or ''
  priority = priority and vim.trim(priority) or ''

  if keyword == '' and priority == '' then
    if tag then edit.remove(tag) end
    return self:refresh()
  end

  local values, key_values = {}, {}
  if tag then
    for key, value in pairs(tag.key_values) do
      if key ~= 'priority' then key_values[key] = unescape(value) end
    end
  end
  if keyword ~= '' then
    values = { keyword }
    if priority ~= '' then values[2] = priority end
  else
    key_values.priority = priority
  end

  local text = assert(edit.build(name, values, key_values, tag and edit.style(tag) or nil))
  if tag then
    edit.replace(tag, text)
  else
    edit.add_to_title(bufnr, self:node(), text, { first = true })
  end
  return self:refresh()
end

---Set the priority, an empty one removes it. The todo keyword is kept.
---@param priority string
function Heading:set_priority(priority)
  local tag = first_title_tag(self, config.fey_status_tag_name)
  return self:_write_status(tag and tag.values[1], priority)
end

---Set the todo keyword, an empty one removes it. The priority is kept.
---@param keyword string
function Heading:set_todo(keyword)
  local tag = first_title_tag(self, config.fey_status_tag_name)
  self:_write_status(keyword, tag and (tag.values[2] or tag.key_values.priority))
  return self:update_parent_cookie()
end

memoize('get_todo')
--- Returns the headings todo keyword (the first plain value of its status tag), the tag node, its type
--- (todo or done) and its index in the todo_keywords list. The status tag has to be the first thing in the
--- title.
--- @return string | nil, TSNode | nil, string | nil, number | nil
function Heading:get_todo()
  local tag = first_title_tag(self, config.fey_status_tag_name)
  local text = tag and tag.values[1]
  if not text then return nil, nil, nil end

  local keyword_by_value = self.file:get_todo_keywords():find(text)
  if not keyword_by_value then return nil, nil, nil, nil end

  return text, tag.node, keyword_by_value.type, keyword_by_value.index
end

---@return boolean
function Heading:is_todo()
  local _, _, type = self:get_todo()
  return type == 'TODO'
end

---@return boolean
function Heading:is_done()
  local _, _, type = self:get_todo()
  return type == 'DONE'
end

memoize('get_title')
---The title of the heading without its metadata tags (todo, priority, labels, ...)
---@return string, number
function Heading:get_title()
  local title_node = self:get_child_node('title')
  if not title_node then return '', 0 end
  local title = require('fey.files.elements.tags.region').title_text(title_node, self.file:get_source(), meta_tag_set())
  return title, select(2, title_node:start())
end

memoize('get_own_properties')
---The properties of the heading: the keys of its `prop` tags in the metadata region, lower case (several
---tags are merged, the last one wins), and the node of the first tag
---@return table<string, string>, TSNode | nil
function Heading:get_own_properties()
  local properties, first_node = {}, nil
  local tags = edit.for_heading(self.file:get_source(), self:node(), { name = config.fey_property_tag_name })
  for _, tag in ipairs(tags) do
    first_node = first_node or tag.node
    for key, value in pairs(tag.key_values) do
      properties[key:lower()] = unescape(value)
    end
  end
  return properties, first_node
end

memoize('get_properties')
---@return table<string, string>, TSNode | nil
function Heading:get_properties()
  local properties, own_properties_node = self:get_own_properties()

  if not config.fey_use_property_inheritance then return properties, own_properties_node end

  local parent = self:get_parent_heading()
  while parent do
    for name, value in pairs((parent:get_own_properties())) do
      if properties[name] == nil and config:use_property_inheritance(name) then properties[name] = value end
    end
    parent = parent:get_parent_heading()
  end

  return properties, own_properties_node
end

---Set a property, or remove it with a nil (or empty) value. The key goes into the tag that has it, else
---into the first `prop` tag of the region, else into a new tag line under the heading.
---@param name string
---@param value? string
---@return FeyHeading
function Heading:set_property(name, value)
  local bufnr = self.file:get_valid_bufnr()
  local key = prop_key(name)
  local tag_name = config.fey_property_tag_name
  local tags = edit.for_heading(bufnr, self:node(), { name = tag_name })

  local holder
  for _, tag in ipairs(tags) do
    if tag.key_values[key] ~= nil then holder = tag end
  end

  if value == nil or tostring(value) == '' then
    if holder then
      local row, col = holder.node:start()
      edit.set_key(holder, key, nil)
      local fresh = edit.at(bufnr, row, col, { name = tag_name })
      if fresh and vim.tbl_isempty(fresh.key_values) and #fresh.values == 0 then edit.remove(fresh) end
    end
    return self:refresh()
  end

  value = tostring(value)
  local target = holder or tags[1]
  if target then
    local ok, err = edit.set_key(target, key, value)
    if not ok then utils.echo_warning(('Cannot set property %s: %s'):format(name, err)) end
  else
    local text, err = edit.build(tag_name, {}, { [key] = value })
    if not text then
      utils.echo_warning(('Cannot set property %s: %s'):format(name, err))
    else
      edit.add_to_region(bufnr, self:node(), text)
    end
  end
  return self:refresh()
end

---Write a note (the lines of a list item) into the heading: at the top of its logbook when
---`fey_log_into_logbook` is on (the logbook is made when there is none), else in its text below the metadata
---@param note string[] | nil
---@return FeyHeading
function Heading:add_note(note)
  if not note then return self end
  if config.fey_log_into_logbook then
    self:add_to_drawer(config.fey_logbook_tag_name, note)
  else
    local append_line = self:get_append_line()
    vim.api.nvim_buf_set_lines(self.file:get_valid_bufnr(), append_line, append_line, false, self:_apply_indent(note))
  end
  EventManager.dispatch(events.NoteAdded:new(self, note))
  return self:refresh()
end

---@param property_name string
---@param search_parents? boolean if true, search parent headings;
---                               if false, only search this heading;
---                               if nil (default), check
---                               `fey_use_property_inheritance`
---@return string | nil, TSNode | nil
function Heading:get_property(property_name, search_parents)
  local key = prop_key(property_name)
  local properties, node = self:get_own_properties()
  if properties[key] ~= nil then return properties[key], node end

  if search_parents == nil then search_parents = config:use_property_inheritance(property_name) end
  if not search_parents then return nil, nil end

  local parent = self:get_parent_heading()
  while parent do
    local own, own_node = parent:get_own_properties()
    if own[key] ~= nil then return own[key], own_node end
    parent = parent:get_parent_heading()
  end

  return nil, nil
end

function Heading:matches_search_term(term)
  if self:get_title():lower():match(term) then return true end
  local body = self.file:get_node_text(self:node():parent():field('body')[1])
  return body:lower():match(term) ~= nil
end

function Heading:content() return self.file:get_node_text_list(self:node():parent():field('body')[1]) end

---@return FeyDate[]
function Heading:get_deadline_and_scheduled_dates()
  local dates = { self:get_deadline_date(), self:get_scheduled_date() }
  return vim.tbl_filter(function(date) return date ~= nil end, dates)
end

---@return FeyDate | nil
function Heading:get_scheduled_date()
  local dates = self:get_planning_dates()
  return vim.tbl_get(dates, 'SCHEDULED', 1)
end

---@return FeyDate | nil
function Heading:get_deadline_date()
  local dates = self:get_planning_dates()
  return vim.tbl_get(dates, 'DEADLINE', 1)
end

memoize('get_labels')
---The labels of the heading and, with `fey_use_label_inheritance`, those of the headings above it and of
---the file
---@return string[], TSNode | nil
function Heading:get_labels()
  local tags, own_tags_node = self:get_own_labels()
  if not config.fey_use_label_inheritance then return tags, own_tags_node end

  local parent_tags = {}
  local parent = self:get_parent_heading()
  while parent do
    utils.concat(parent_tags, utils.reverse((parent:get_own_labels())), true)
    parent = parent:get_parent_heading()
  end
  local file_tags = self.file:get_filetags()

  local all_tags = utils.concat({}, file_tags)
  utils.concat(all_tags, utils.reverse(parent_tags), true)
  all_tags = config:exclude_tags(all_tags)
  utils.concat(all_tags, tags, true)

  return all_tags, own_tags_node
end

---@return FeyHeading | nil
function Heading:get_parent_heading()
  local parent_section = self:node():parent():parent()
  if not parent_section then return nil end

  local heading = parent_section:field('heading')[1]
  if not heading then return nil end -- the document itself
  return Heading:new(heading, self.file)
end

memoize('get_own_labels')
---The labels written in the metadata region of the heading (title and tag lines), and the node of the
---first label tag
---@return string[], TSNode | nil
function Heading:get_own_labels()
  local names = label_names()
  local labels, first_node = {}, nil
  for _, tag in ipairs((edit.for_heading(self.file:get_source(), self:node()))) do
    if vim.tbl_contains(names, tag.name) then
      first_node = first_node or tag.node
      for _, value in ipairs(tag.values) do
        for part in value:gmatch('[^,;]+') do
          local label = vim.trim(part)
          if label ~= '' and not vim.tbl_contains(labels, label) then table.insert(labels, label) end
        end
      end
    end
  end
  return labels, first_node
end

---@return FeyDate[]
function Heading:get_repeater_dates()
  return vim.tbl_filter(function(date) return date:get_repeater() end, self:get_all_dates())
end

---@return boolean
function Heading:is_first_section() return self:get_prev_heading_same_level() == nil end

---@return boolean
function Heading:is_last_section() return self:get_next_heading_same_level() == nil end

---@return FeyHeading | nil
function Heading:get_prev_heading_same_level()
  local prev_section = self:node():parent():prev_named_sibling()
  if not prev_section or prev_section:type() ~= 'section' then return nil end

  return Heading:new(prev_section:field('heading')[1], self.file)
end

---@return FeyHeading | nil
function Heading:get_next_heading_same_level()
  local next_section = self:node():parent():next_named_sibling()
  if not next_section or next_section:type() ~= 'section' then return nil end

  return Heading:new(next_section:field('heading')[1], self.file)
end

---The line (0-based) new lines under the heading go to: after the last line of tags of its metadata
---region, or directly under the heading
---@return number
function Heading:get_append_line()
  local _, last_row = edit.for_heading(self.file:get_source(), self:node(), { region = 'body' })
  if last_row then return last_row + 1 end
  return (self:node():end_())
end

---Names of the planning tags and the kind of date each stands for
---@return table<string, FeyPlanningDateTypes>
local function plan_tag_types()
  return {
    [config.fey_scheduled_tag_name] = 'SCHEDULED',
    [config.fey_deadline_tag_name] = 'DEADLINE',
    [config.fey_closed_tag_name] = 'CLOSED',
  }
end

---The planning tags in the metadata region of the heading, the first of each kind
---@private
---@param source? integer|string defaults to the source of the file
---@return table<FeyPlanningDateTypes, FeyMetaTag>
function Heading:_plan_tags(source)
  local types, tags = plan_tag_types(), {}
  for _, tag in ipairs((edit.for_heading(source or self.file:get_source(), self:node()))) do
    local type_ = types[tag.name]
    if type_ and not tags[type_] then tags[type_] = tag end
  end
  return tags
end

memoize('get_planning_dates')
---@return FeyTable<FeyPlanningDateTypes, FeyDate[]>,FeyTable<FeyPlanningDateTypes, TSNode>, boolean
function Heading:get_planning_dates()
  local dates, dates_nodes, has_planning_dates = {}, {}, false
  for type_, tag in pairs(self:_plan_tags()) do
    dates[type_] = Date.from_tag(tag, { type = type_ })
    dates_nodes[type_] = tag.node
    has_planning_dates = true
  end
  return dates, dates_nodes, has_planning_dates
end

memoize('get_all_dates')
---Return all dates including the ones added to the body of the heading
---@return FeyDate[]
function Heading:get_all_dates()
  local d = self:get_planning_dates()
  local planning_dates = utils.flatten(vim.tbl_values(d))
  local body_dates_list = self:get_non_planning_dates()

  return vim.list_extend(planning_dates, body_dates_list)
end

local date_tag_query
memoize('get_non_planning_dates')
---Dates written in the title and the body of the heading (date tags), not the planning tags
---@return FeyDate[]
function Heading:get_non_planning_dates()
  local heading_node = self:node()
  local section = heading_node:parent()
  if not section then return {} end
  date_tag_query = date_tag_query or vim.treesitter.query.parse('fey', '[(scope_tag) (line_tag)] @tag')

  local source = self.file:get_source()
  local all_dates = {}
  for _, owner in ipairs({ heading_node:field('title')[1], section:field('body')[1] }) do
    if owner then
      for _, node in date_tag_query:iter_captures(owner, source) do
        local name = node:field('name')[1]
        if name and vim.treesitter.get_node_text(name, source) == config.fey_date_tag_name then
          vim.list_extend(all_dates, Date.from_node(node, source))
        end
      end
    end
  end
  return all_dates
end

---@param sorted? boolean
---@return string, TSNode | nil
function Heading:labels_to_string(sorted)
  local tags, node = self:get_labels()
  return utils.labels_to_string(tags, sorted), node
end

---@return boolean
function Heading:has_child_headings() return self:node():parent():field('subsection')[1] ~= nil end

---@return boolean
function Heading:is_one_line()
  local start_row, _, end_row, end_col = self:node():parent():range()
  -- One line sections have end range on the next line with 0 column
  -- Example: If heading is on line 5, range will be (5, 1, 6, 0)
  return start_row == end_row or (start_row + 1 == end_row and end_col == 0)
end

memoize('get_child_headings')
---@return FeyHeading[]
function Heading:get_child_headings()
  local child_sections = self:node():parent():field('subsection')
  local headings = vim.tbl_map(
    function(child_section) return Heading:new(child_section:field('heading')[1], self.file) end,
    child_sections
  )

  return headings
end

---@param category string
---@return boolean
function Heading:matches_category(category) return self:get_category() == category end

---@return FeyDate[]
function Heading:get_valid_dates_for_agenda()
  local dates = {}
  for _, date in ipairs(self:get_all_dates()) do
    if date.active and not date:is_closed() and not date:is_obsolete_range_end() then
      table.insert(dates, date)
      if not date:is_none() and date.related_date then
        local new_date = date:clone({ type = 'NONE' })
        table.insert(dates, new_date)
      end
    end
  end
  return dates
end

---@param date FeyDate
function Heading:set_deadline_date(date) return self:_add_date('DEADLINE', date, true) end

---@param date FeyDate
function Heading:set_scheduled_date(date) return self:_add_date('SCHEDULED', date, true) end

---@param date? FeyDate
function Heading:set_closed_date(date)
  local dates = self:get_planning_dates()
  if vim.tbl_get(dates, 'CLOSED', 1) then return end
  return self:_add_date('CLOSED', date or Date.now(), false)
end

function Heading:remove_closed_date() return self:_remove_date('CLOSED') end

function Heading:remove_deadline_date() return self:_remove_date('DEADLINE') end

function Heading:remove_scheduled_date() return self:_remove_date('SCHEDULED') end

function Heading:get_cookie()
  local cookie = self:_parse_title_part('%[%d*/%d*%]')
  if cookie then return cookie end
  return self:_parse_title_part('%[%d?%d?%d?%%%]')
end

function Heading:_set_cookie(cookie, num, denum)
  -- Update the cookie
  return self:_set_node_text(cookie, Checkbox.cookie(self.file:get_node_text(cookie), num, denum))
end

function Heading:update_cookie()
  -- Update cookie state from a check box state change

  -- Return early if the heading doesn't have a cookie
  local cookie = self:get_cookie()
  if not cookie then return self end

  local section = self:node():parent()
  if not section then return self end

  -- Count checked boxes from all lists
  local num_checked_boxes, num_boxes = 0, 0
  local body = section:field('body')[1]
  if body then
    for node in body:iter_children() do
      if node:type() == 'list' then
        local checked, total = Checkbox.progress(self:child_checkboxes(node))
        num_boxes = num_boxes + total
        num_checked_boxes = num_checked_boxes + checked
      end
    end
  end

  -- Set the cookie
  return self:_set_cookie(cookie, num_checked_boxes, num_boxes)
end

function Heading:update_todo_cookie()
  -- Update cookie state from a TODO state change

  -- Return early if the heading doesn't have a cookie
  local cookie = self:get_cookie()
  if not cookie then return self end

  -- Count done children headings and total children with TODO keywords
  local children = self:get_child_headings()
  local headings_with_todo = vim.tbl_filter(function(h)
    local todo, _, _ = h:get_todo()
    return todo ~= nil
  end, children)

  local dones = vim.tbl_filter(function(h) return h:is_done() end, headings_with_todo)

  -- Set the cookie
  return self:_set_cookie(cookie, #dones, #headings_with_todo)
end

function Heading:update_parent_cookie()
  local parent = self:get_parent_heading()
  if parent and parent.heading then parent:update_todo_cookie() end
  return self
end

function Heading:child_checkboxes(list_node) return require('fey.files.elements.listitem').boxes_of_list(list_node, self.file) end

---A drawer of the heading: the pair tag `[ name #]` ... `[# name ]` or the block tag `[ name ]#` with that name in
---its own text (not in a subsection). The logbook of the clock and of notes is one.
---@param name string matched case insensitively
---@return TSNode | nil pair_tag or block_tag
function Heading:get_drawer(name)
  local section = self:node():parent()
  if not section then return nil end
  local body = section:field('body')[1]
  if not body then return nil end
  for _, node in ipairs(ts_utils.get_named_children(body)) do
    if node:type() == 'pair_tag' or node:type() == 'block_tag' then
      local head = node:type() == 'pair_tag' and node:field('open')[1] or node
      local tag_name = head and head:field('name')[1]
      if tag_name and self.file:get_node_text(tag_name):lower() == name:lower() then return node end
    end
  end
end

---The lines of a new drawer in the form the config asks for (`fey_drawer_form`): a pair tag, or a block tag with
---the lines indented under it. A block tag with no lines is only its head.
---@param name string
---@param lines? string[]
---@param indent? string indentation of the tag
---@return string[]
function Heading.drawer_lines(name, lines, indent)
  indent = indent or ''
  lines = lines or {}
  if config.fey_drawer_form == 'block' then
    local out = { ('%s[ %s ]#'):format(indent, name) }
    for _, line in ipairs(lines) do
      out[#out + 1] = line ~= '' and (indent .. Heading.DRAWER_INDENT .. line) or ''
    end
    return out
  end
  local out = { ('%s[ %s #]'):format(indent, name) }
  for _, line in ipairs(lines) do
    out[#out + 1] = line ~= '' and (indent .. line) or ''
  end
  out[#out + 1] = ('%s[# %s ]'):format(indent, name)
  return out
end

---How far the body of a block tag drawer is indented
Heading.DRAWER_INDENT = '   '

---The line (0-based, to insert before it) at the top of the drawer with the given name, right under its
---head: new entries go first. The drawer is made, under the metadata of the heading, when there is none.
---@param name string
---@return number row
---@return string indent what the lines written there start with: nothing in a pair tag, the indent of the body of a block tag
function Heading:get_drawer_append_line(name)
  local drawer = self:get_drawer(name)
  local bufnr = self.file:get_valid_bufnr()
  if not drawer then
    local at = self:get_append_line()
    local block = Heading.drawer_lines(name)
    local following = vim.api.nvim_buf_get_lines(bufnr, at, at + 1, false)[1]
    if following and following:match('%S') then block[#block + 1] = '' end
    vim.api.nvim_buf_set_lines(bufnr, at, at, false, block)
    -- the tree is old: the drawer is what was just written
    return at + 1, config.fey_drawer_form == 'block' and Heading.DRAWER_INDENT or ''
  end
  local head = drawer:type() == 'pair_tag' and drawer:field('open')[1] or drawer
  local closure = head:field('tag_closure')
  local last = closure[#closure] or head
  local _, _, head_end_row = last:range()
  local row = head_end_row + 1
  if drawer:type() == 'pair_tag' then return row, '' end
  local first = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
  local opener = vim.api.nvim_buf_get_lines(bufnr, (drawer:start()), (drawer:start()) + 1, false)[1] or ''
  local indent = first and first:match('%S') and first:match('^%s*') or (opener:match('^%s*') .. Heading.DRAWER_INDENT)
  return row, indent
end

memoize('get_range')
---@return FeyRange
function Heading:get_range() return Range.from_node(self:node():parent()) end

---@return string[]
function Heading:get_lines() return self.file:get_node_text_list(self:node():parent()) end

memoize('get_heading_line_content')
---@return string
function Heading:get_heading_line_content()
  local line = self.file:get_node_text(self:node()):gsub('\n', '')
  return line
end

---@param amount? number
---@return string
function Heading:get_indent(amount) return config:get_indent(amount or self:get_signature_width() + 1, self.file:bufnr()) end

function Heading:is_same(other_heading)
  return self.file.filename == other_heading.filename
    and self:get_range():is_same(other_heading:get_range())
    and self:get_heading_line_content() == other_heading:get_heading_line_content()
end

function Heading:id_get_or_create()
  local id_prop = self:get_property('ID', false)
  if id_prop then return vim.trim(id_prop) end
  local fey_id = FeyId.new()
  self:set_property('ID', fey_id)
  return fey_id
end

---Write a planning date: replaces the tag of that kind, else goes next to the other planning tags,
---else to a line of its own under the heading
---@param type FeyPlanningDateTypes
---@param date FeyDate
---@param active? boolean
---@private
function Heading:_add_date(type, date, active)
  local bufnr = self.file:get_valid_bufnr()
  local text = date:clone({ type = type, active = active }):to_tag_text()
  local tags = self:_plan_tags(bufnr)

  if tags[type] then
    edit.replace(tags[type], text)
    return self:refresh()
  end

  local anchor
  for _, tag in pairs(tags) do
    local row, col = tag.node:start()
    if not anchor or row > anchor.row or (row == anchor.row and col > anchor.col) then
      anchor = { row = row, col = col, node = tag.node }
    end
  end
  if anchor then
    local er, ec = anchor.node:end_()
    vim.api.nvim_buf_set_text(bufnr, er, ec, er, ec, { ' ' .. text })
  else
    edit.add_to_region(bufnr, self:node(), text)
  end
  return self:refresh()
end

---@param type FeyPlanningDateTypes
---@private
function Heading:_remove_date(type)
  local tag = self:_plan_tags(self.file:get_valid_bufnr())[type]
  if not tag then return end
  edit.remove(tag)
  return self:refresh()
end

---@param text string[]|string
---@param amount? number
function Heading:_apply_indent(text, amount)
  local indent_text = self:get_indent(amount)

  if indent_text == '' then return text end

  if type(text) ~= 'table' then return indent_text .. text end

  for i, line in ipairs(text) do
    text[i] = indent_text .. line
  end

  return text
end

function Heading:get_child_node(name) return self:node():field(name)[1] end

---@param node? TSNode
---@param text string
---@return FeyHeading
function Heading:_set_node_text(node, text)
  self.file:set_node_text(node, text)
  return self:refresh()
end

---@param node? TSNode
---@param text string[]
---@return FeyHeading
function Heading:_set_node_lines(node, text)
  self.file:set_node_lines(node, text)
  return self:refresh()
end

---@private
---@return TSNode | nil, string
function Heading:_parse_title_part(pattern)
  for _, node in ipairs(ts_utils.get_named_children(self:get_child_node('title'))) do
    local text = self.file:get_node_text(node) or ''
    local match = text:match(pattern)
    if match then return node, match end
  end

  return nil, ''
end

---@private
---@param recursive? boolean
---@param modifier function
---@param dryRun? boolean
function Heading:_handle_promote_demote(recursive, modifier, dryRun)
  local current_node = self:node()
  local parent_section = current_node:parent()
  if not parent_section then
    local row, col = current_node:start()
    utils.echo_error('Cannot find heading section.', { 'Line: ' .. row .. ', Col: ' .. col })
    return self
  end

  local child_sections = parent_section:field('subsection')
  local first_child_section = child_sections[1]

  local start = current_node:start()
  local end_line = first_child_section and first_child_section:start() or parent_section:end_()

  local bufnr = self.file:get_valid_bufnr()
  local modified_lines = modifier(start, vim.api.nvim_buf_get_lines(bufnr, start, end_line, false), self)

  local result_lines = {}

  if dryRun then
    vim.list_extend(result_lines, modified_lines)
  else
    vim.api.nvim_buf_set_lines(bufnr, start, end_line, false, modified_lines)
  end

  if recursive then
    for _, child_node in ipairs(child_sections) do
      local child_heading = Heading:new(child_node:field('heading')[1], self.file)
      local child_res = child_heading:_handle_promote_demote(true, modifier, dryRun)
      if dryRun and child_res then vim.list_extend(result_lines, child_res) end
    end
  end

  if dryRun then return result_lines end

  return self:refresh()
end

---Add lines at the top of a drawer of the heading
---@param drawer_name string
---@param content string|string[]
---@return FeyHeading
function Heading:add_to_drawer(drawer_name, content)
  local append_line, indent = self:get_drawer_append_line(drawer_name)
  local lines = type(content) == 'table' and content or { content }
  if indent ~= '' then
    lines = vim.tbl_map(function(line) return line ~= '' and (indent .. line) or '' end, lines)
  end
  vim.api.nvim_buf_set_lines(self.file:get_valid_bufnr(), append_line, append_line, false, lines)
  return self:refresh()
end

-- the old names, kept for a release (III.R)
do
  local alias = require('fey.utils.deprecate').alias
  alias(Heading, 'get_tags', 'get_labels', 'Heading:get_tags')
  alias(Heading, 'get_own_tags', 'get_own_labels', 'Heading:get_own_tags')
  alias(Heading, 'has_tag', 'has_label', 'Heading:has_tag')
  alias(Heading, 'set_tags', 'set_labels', 'Heading:set_tags')
  alias(Heading, 'add_tag', 'add_label', 'Heading:add_tag')
  alias(Heading, 'tags_to_string', 'labels_to_string', 'Heading:tags_to_string')
  alias(Heading, 'get_plan_dates', 'get_planning_dates', 'Heading:get_plan_dates')
  alias(Heading, 'get_non_plan_dates', 'get_non_planning_dates', 'Heading:get_non_plan_dates')
  alias(Heading, 'get_outline_path', 'get_heading_path', 'Heading:get_outline_path')
end

return Heading
