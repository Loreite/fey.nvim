local Calendar = require('fey.objects.calendar')
local Date = require('fey.objects.date')
local EditSpecial = require('fey.objects.edit_special')
local Help = require('fey.objects.help')
local FeyHyperlink = require('fey.fey.links.hyperlink')
local PriorityState = require('fey.objects.priority_state')
local TodoState = require('fey.objects.todo_state')
local config = require('fey.config')
local constants = require('fey.utils.constants')
local ts_utils = require('fey.utils.treesitter')
local utils = require('fey.utils')
local Table = require('fey.files.elements.table')
local EventManager = require('fey.events')
local events = EventManager.event
local Babel = require('fey.babel')
local Promise = require('fey.utils.promise')
local Input = require('fey.ui.input')
local indent = require('fey.fey.indent')
local Footnote = require('fey.objects.footnote')
local sequences = require('fey.utils.sequences')
local FeyFile = require('fey.files.file')

---Schedule a fold update for the given range. Call after buffer edits.
---FeyRange is 1-indexed; vim._foldupdate expects 0-indexed lines.
---@param range FeyRange
local function schedule_fold_update(range)
  local bufnr = vim.api.nvim_get_current_buf()
  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    local start_line = range.start_line - 1
    local end_line = math.min(range.end_line, vim.api.nvim_buf_line_count(bufnr))
    for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
      if vim.wo[win].foldmethod == 'expr' then vim._foldupdate(win, start_line, end_line) end
    end
  end)
end

---@class FeyMappings
---@field capture FeyCapture
---@field agenda FeyAgenda
---@field files FeyFiles
---@field links FeyLinks
---@field completion FeyCompletion
local FeyMappings = {}

---@param data table
function FeyMappings:new(data)
  local opts = {}
  opts.global_cycle_mode = 'all'
  opts.capture = data.capture
  opts.agenda = data.agenda
  opts.files = data.files
  opts.links = data.links
  opts.completion = data.completion
  setmetatable(opts, self)
  self.__index = self
  return opts
end

-- TODO:
-- Support archiving to heading
function FeyMappings:archive() return self.capture:refile_file_heading_to_archive(self.files:get_closest_heading()) end

---@param tags? string|string[]
function FeyMappings:set_tags(tags)
  local heading = self.files:get_closest_heading()
  local heading_tags = heading:get_own_tags()
  local current_tags = utils.tags_to_string(heading_tags)
  -- Capture range before promise chain — TS nodes become stale after edits
  local range = heading:get_range()

  return Promise.resolve()
    :next(function()
      if not tags then
        return Input.open(
          'Tags: ',
          current_tags,
          function(arg_lead) return utils.prompt_autocomplete(arg_lead, self.files:get_tags()) end
        )
      end
      if type(tags) == 'table' then tags = utils.tags_to_string(tags) end

      return tags
    end)
    :next(function(new_tags)
      if not new_tags then return end

      heading:set_tags(new_tags)
      schedule_fold_update(range)
    end)
end

---@return nil
function FeyMappings:toggle_archive_tag()
  local heading = self.files:get_closest_heading()
  local range = heading:get_range()
  heading:toggle_tag('ARCHIVE')
  schedule_fold_update(range)
end

function FeyMappings:cycle()
  local file = self.files:get_current_file()
  if not file then return end
  local line = vim.fn.line('.') or 0
  if not vim.wo.foldenable then
    vim.wo.foldenable = true
    vim.cmd([[silent! norm!zx]])
  end
  local level = vim.fn.foldlevel(line)
  if level == 0 then return utils.echo_info('No fold') end
  local is_fold_closed = vim.fn.foldclosed(line) ~= -1
  if is_fold_closed then return vim.cmd([[silent! norm!zo]]) end
  local section = file:get_closest_heading_or_nil({ line, 0 })

  if not section then
    -- Toggle drawers
    if vim.fn.getline(line):match('^%s*:[^:]*:%s*$') then vim.cmd([[silent! norm!za]]) end
    return
  end

  local is_expandable = function(heading) return heading:has_child_headings() or not heading:is_one_line() end

  -- Skip one liner
  if not is_expandable(section) then return end

  local children = section:get_child_headings()
  local close = #children == 0

  if not close then
    local has_nested_children = false
    for _, child in ipairs(children) do
      local is_child_expandable = is_expandable(child)
      if not has_nested_children and is_child_expandable then has_nested_children = true end
      local child_range = child:get_range()
      if is_child_expandable and vim.fn.foldclosed(child_range.start_line) == -1 then
        vim.cmd(string.format('silent! keepjumps norm!%dggzc', child_range.start_line))
        close = true
      end
    end
    vim.cmd(string.format('silent! keepjumps norm!%dgg', line))
    if not close and not has_nested_children then close = true end
  end

  if close then return vim.cmd([[silent! norm!zc]]) end
  return vim.cmd([[silent! norm!zczO]])
end

function FeyMappings:global_cycle()
  if not vim.wo.foldenable or self.global_cycle_mode == 'Show All' then
    self.global_cycle_mode = 'Overview'
    utils.echo_info(self.global_cycle_mode)
    return vim.cmd([[silent! norm!zMzX]])
  end
  if self.global_cycle_mode == 'Contents' then
    self.global_cycle_mode = 'Show All'
    utils.echo_info(self.global_cycle_mode)
    return vim.cmd([[silent! norm!zR]])
  end
  self.global_cycle_mode = 'Contents'
  utils.echo_info(self.global_cycle_mode)
  vim.wo.foldlevel = 1
  return vim.cmd([[silent! norm!zx]])
end

function FeyMappings:fey_babel_tangle() return Babel.tangle(self.files:get_current_file()) end

function FeyMappings:toggle_checkbox()
  local win_view = vim.fn.winsaveview() or {}
  -- move to the first non-blank character so the current treesitter node is the listitem
  vim.cmd([[normal! _]])

  local listitem = self.files:get_closest_listitem()
  if listitem then listitem:update_checkbox('toggle') end

  vim.fn.winrestview(win_view)
end

function FeyMappings:timestamp_up_day()
  return self:_adjust_date(vim.v.count1, 'd', vim.v.count1 .. config.mappings.fey.fey_timestamp_up_day)
end

function FeyMappings:timestamp_down_day()
  return self:_adjust_date(-vim.v.count1, 'd', vim.v.count1 .. config.mappings.fey.fey_timestamp_down_day)
end

function FeyMappings:timestamp_up()
  return self:_adjust_date_part('+', vim.v.count1, vim.v.count1 .. config.mappings.fey.fey_timestamp_up)
end

function FeyMappings:timestamp_down()
  return self:_adjust_date_part('-', vim.v.count1, vim.v.count1 .. config.mappings.fey.fey_timestamp_down)
end

function FeyMappings:_adjust_date_part(direction, amount, fallback)
  local date_on_cursor = self:_get_date_under_cursor()
  local get_adj = function(span, count) return string.format('%d%s', count or amount, span) end
  local minute_adj = get_adj('M', tonumber(config.fey_time_stamp_rounding_minutes) * amount)
  ---@param date FeyDate
  local do_replacement = function(date)
    local col = vim.fn.col('.') or 0
    local char = vim.fn.getline('.'):sub(col, col)
    local raw_date_value = vim.fn.getline('.'):sub(date.range.start_col + 1, date.range.end_col - 1)
    if col == date.range.start_col or col == date.range.end_col then
      date.active = not date.active
      return self:_replace_date(date)
    end
    local col_from_start = col - date.range.start_col
    local parts = Date.from_string(raw_date_value):parse_parts()
    local adj = nil
    local modify_end_time = false
    local part = nil
    for _, p in ipairs(parts) do
      if col_from_start >= p.from and col_from_start <= p.to then
        part = p
        break
      end
    end

    if not part then return end

    local offset = col_from_start - part.from

    if part.type == 'date' then
      if offset <= 4 then
        adj = get_adj('y')
      elseif offset <= 7 then
        adj = get_adj('m')
      else
        adj = get_adj('d')
      end
    end

    if part.type == 'dayname' then adj = get_adj('d') end

    if part.type == 'time' then
      if offset <= 2 then
        adj = get_adj('h')
      else
        adj = minute_adj
      end
    end

    if part.type == 'time_range' then
      if offset <= 2 then
        adj = get_adj('h')
      elseif offset <= 5 then
        adj = minute_adj
      elseif offset <= 8 then
        adj = get_adj('h')
        modify_end_time = true
      else
        adj = minute_adj
        modify_end_time = true
      end
    end

    if part.type == 'adjustment' then
      local map = { h = 'd', d = 'w', w = 'm', m = 'y', y = 'h' }
      if map[char] then vim.cmd(string.format('norm!r%s', map[char])) end
      return true
    end

    if not adj then return false end

    local new_date = nil
    if modify_end_time then
      new_date = date:adjust_end_time(direction .. adj)
    else
      new_date = date:adjust(direction .. adj)
    end

    self:_replace_date(new_date)

    if date:is_logbook() and date.related_date then
      local item = self.files:get_closest_heading_or_nil()
      if item then
        local logbook = item:get_logbook()
        if logbook then logbook:recalculate_estimate(new_date.range.start_line) end
      end
    end
    return true
  end

  if date_on_cursor then
    local replaced = do_replacement(date_on_cursor)
    if replaced then return true end
  end

  return vim.api.nvim_feedkeys(utils.esc(fallback), 'n', true)
end

function FeyMappings:change_date()
  local date = self:_get_date_under_cursor()
  if not date then return end
  return Calendar.new({ date = date, title = 'Change date' }):open():next(function(new_date)
    if new_date then self:_replace_date(new_date) end
  end)
end

function FeyMappings:priority_up() self:set_priority('up') end

function FeyMappings:priority_down() self:set_priority('down') end

function FeyMappings:set_priority(direction)
  local heading = self.files:get_closest_heading()
  local current_priority = heading:get_priority()
  local prio_range = config:get_priority_range()
  local priority_state = PriorityState:new(current_priority, prio_range, config.fey_priority_start_cycle_with_default)

  local new_priority = direction
  if direction == 'up' then
    new_priority = priority_state:increase()
  elseif direction == 'down' then
    new_priority = priority_state:decrease()
  elseif direction == nil then
    new_priority = priority_state:prompt_user()
    if new_priority == nil then return end
  end

  local range = heading:get_range()
  heading:set_priority(new_priority)
  schedule_fold_update(range)
end

function FeyMappings:todo_next_state() return self:_todo_change_state('next') end

function FeyMappings:todo_prev_state() return self:_todo_change_state('prev') end

function FeyMappings:toggle_heading()
  local line_number = vim.fn.line('.')
  local line = vim.fn.getline(line_number)
  local parent = self.files:get_closest_heading_or_nil()

  local set_line_and_dispatch_event = function(line_content, action)
    vim.fn.setline(line_number, line_content)
    EventManager.dispatch(
      events.HeadingToggled:new(line_number, action, self.files:get_closest_heading_or_nil({ line_number, 0 }))
    )
  end
  -- Convert to heading
  if not parent then return set_line_and_dispatch_event('* ' .. line, 'line_to_heading') end

  -- Convert heading to plain text
  if parent:get_range().start_line == vim.api.nvim_win_get_cursor(0)[1] then
    line = line:gsub('^%*+%s', '')
    return set_line_and_dispatch_event(line, 'heading_to_line')
  end

  line = line:gsub('^(%s*)', '')
  if line:match('^[%*-]%s') then -- handle lists
    line = line:gsub('^[%*-]%s', '') -- strip bullet
    local todo_keywords = self.files:get_current_file():get_todo_keywords()
    line = line:gsub('^%[([X%s])%]%s', function(checkbox_state)
      if checkbox_state == 'X' then
        return todo_keywords:first_by_type('DONE').value .. ' '
      else
        return todo_keywords:first_by_type('TODO').value .. ' '
      end
    end)
  end

  line = string.rep('*', parent:get_level() + 1) .. ' ' .. line

  return set_line_and_dispatch_event(line, 'line_to_child_heading')
end

---Prompt for a note
---@private
---@param template string
---@param indent string
---@param title string
---@return FeyPromise<string[]>
function FeyMappings:_get_note(template, indent, title)
  return self.capture:build_note_capture(title):open():next(function(closing_note)
    if closing_note == nil then return end

    for i, line in ipairs(closing_note) do
      closing_note[i] = indent .. '  ' .. line
    end

    return vim.list_extend({ template }, closing_note)
  end)
end

function FeyMappings:_todo_change_state(direction)
  local heading = self.files:get_closest_heading()
  local old_state = heading:get_todo()
  local was_done = heading:is_done()

  local range = heading:get_range()

  local changed = self:_change_todo_state(direction, true)

  if not changed then return end

  local item = self.files:get_closest_heading()
  EventManager.dispatch(events.TodoChanged:new(item, old_state, was_done))

  schedule_fold_update(range)

  local is_done = item:is_done() and not was_done
  local is_undone = not item:is_done() and was_done

  -- State was changed in the same group (TODO NEXT | DONE)
  -- For example: Changed from TODO to NEXT
  if not is_done and not is_undone then return item end

  local prompt_done_note = config.fey_log_done == 'note'
  local log_closed_time = config.fey_log_done == 'time'
  local indent = heading:get_indent()

  local closing_note_text = ('%s- CLOSING NOTE %s \\\\'):format(indent, Date.now():to_wrapped_string(false))
  local closed_title = 'Insert note for closed todo item'

  local repeater_dates = item:get_repeater_dates()

  -- No dates with a repeater. Add closed date and note if enabled.
  if #repeater_dates == 0 then
    local set_closed_date = prompt_done_note or log_closed_time
    if set_closed_date then
      if is_done then
        heading:set_closed_date()
      elseif is_undone then
        heading:remove_closed_date()
      end
      item = self.files:get_closest_heading()
    end

    if is_undone or not prompt_done_note then return item end

    return self
      :_get_note(closing_note_text, indent, closed_title)
      :next(function(closing_note) return item:add_note(closing_note) end)
  end

  for _, date in ipairs(repeater_dates) do
    self:_replace_date(date:apply_repeater())
  end

  local new_todo = item:get_todo()

  -- Reset to first TODO of the same sequence for repeating tasks
  local todos = item.file:get_todo_keywords()
  local todo_state = TodoState:new({ current_state = new_todo, todos = todos })
  local reset_keyword = todo_state:get_reset_todo(item, old_state)

  item:set_todo(reset_keyword.value)

  local prompt_repeat_note = config.fey_log_repeat == 'note'
  local log_repeat_enabled = config.fey_log_repeat ~= false
  local repeat_note_template = ('%s- State %-12s from %-12s [%s]'):format(
    indent,
    [["]] .. new_todo .. [["]],
    [["]] .. (old_state or '') .. [["]],
    Date.now():to_string()
  )
  local repeat_note_title = ('Insert note for state change from "%s" to "%s"'):format(old_state or '', new_todo)

  if log_repeat_enabled then item:set_property('LAST_REPEAT', Date.now():to_wrapped_string(false)) end

  if not prompt_repeat_note and not prompt_done_note then
    -- If user is not prompted for a note, use a default repeat note
    if log_repeat_enabled then return item:add_note({ repeat_note_template }) end
    return item
  end

  -- Done note has precedence over repeat note
  if prompt_done_note then
    return self
      :_get_note(closing_note_text, indent, closed_title)
      :next(function(closing_note) return item:add_note(closing_note) end)
  end

  return self
    :_get_note(repeat_note_template .. ' \\\\', indent, repeat_note_title)
    :next(function(closing_note) return item:add_note(closing_note) end)
end

function FeyMappings:do_promote(whole_subtree)
  local count = vim.v.count1
  local win_view = vim.fn.winsaveview() or {}
  -- move to the first non-blank character so the current treesitter node is the listitem
  vim.cmd([[normal! _]])

  local node = ts_utils.get_node_at_cursor()
  local set = utils.set({ 'bullet', 'segment', 'list' })
  if node and set[node:type()] then
    local listitem = self.files:get_closest_listitem()
    if listitem then
      listitem:promote(whole_subtree)
      vim.fn.winrestview(win_view)

      -- trigger reindex
      local bufnr = vim.api.nvim_get_current_buf()
      local feyfile = FeyFile:new({ filename = vim.api.nvim_buf_get_name(bufnr), buf = bufnr })
      EventManager.dispatch(events.BufferChanged:new(feyfile, true))
      return
    end
  end

  local heading = self.files:get_closest_heading()
  local old_level = heading:get_level()
  local foldclosed = vim.fn.foldclosed('.')
  heading:promote(count, whole_subtree)
  if foldclosed > -1 and vim.fn.foldclosed('.') == -1 then vim.cmd([[norm!zc]]) end
  EventManager.dispatch(events.HeadingPromoted:new(self.files:get_closest_heading(), old_level))
  vim.fn.winrestview(win_view)
end

function FeyMappings:do_demote(whole_subtree)
  local count = vim.v.count1
  local win_view = vim.fn.winsaveview() or {}
  -- move to the first non-blank character so the current treesitter node is the listitem
  vim.cmd([[normal! _]])

  local node = ts_utils.get_node_at_cursor()
  local set = utils.set({ 'bullet', 'segment', 'list' })
  if node and set[node:type()] then
    local listitem = self.files:get_closest_listitem()
    if listitem then
      listitem:demote(whole_subtree)
      vim.fn.winrestview(win_view)

      -- trigger reindex
      local bufnr = vim.api.nvim_get_current_buf()
      local feyfile = FeyFile:new({ filename = vim.api.nvim_buf_get_name(bufnr), buf = bufnr })
      EventManager.dispatch(events.BufferChanged:new(feyfile, true))
      return
    end
  end

  local heading = self.files:get_closest_heading()
  local old_level = heading:get_level()
  local foldclosed = vim.fn.foldclosed('.')
  heading:demote(count, whole_subtree)
  if foldclosed > -1 and vim.fn.foldclosed('.') == -1 then vim.cmd([[norm!zc]]) end
  EventManager.dispatch(events.HeadingDemoted:new(self.files:get_closest_heading(), old_level))
  vim.fn.winrestview(win_view)
end

local function setup_heading_func(mappings)
  local data = {}
  data.count = vim.v.count1
  data.heading = mappings.files:get_closest_heading()
  data.signature = data.heading:get_child_node('signature')
  data.startl, data.startc, data.endl, data.endc = data.signature:range()
  data.level = data.heading:get_level()
  data.count = math.min(data.count, data.level)
  data.segments = data.signature:named_children()
  data.bufnr = vim.api.nvim_get_current_buf()
  data.new_sig = ''
  data.converted = 0
  return data
end

local function setup_reversible_loop(from_start, seg_len)
  return (from_start and 1 or seg_len), (from_start and seg_len or 1), (from_start and 1 or -1)
end

local function get_segment_parts(segment, bufnr)
  return vim.treesitter.get_node_text(assert(segment:child(0)), bufnr),
    vim.treesitter.get_node_text(assert(segment:child(1)), bufnr)
end

local function submit_heading_change(data)
  local lines = vim.api.nvim_buf_get_lines(data.bufnr, data.startl, data.endl + 1, false)
  lines[1] = lines[1]:sub(1, data.startc) .. '  ' .. data.new_sig .. lines[1]:sub(data.endc + 1)
  vim.api.nvim_buf_set_lines(data.bufnr, data.startl, data.endl + 1, false, lines)
end

local function enumerate_segment(data, from_start)
  local idx = from_start and data.converted or (data.level - data.converted + 1)
  local pattern_idx = ((idx - 1) % #config.fey_default_subheading_index_order) + 1
  local pattern = config.fey_default_subheading_index_order[pattern_idx]
  return sequences.patterns[pattern].to_symbol(1)
end

function FeyMappings:change_all_delimiters(from_start)
  local data = setup_heading_func(self)
  if vim.v.count == 0 then data.count = data.level end
  local s, e, d = setup_reversible_loop(from_start, #data.segments)

  local input = vim.fn.input('Delimiter: ')
  input = input:gsub('[^.,:;!?/\\\'"`%-+*=~^@&#$%%%[%](){}<>]', '')
  if input == '' then input = config.fey_default_subheading_delimiter_order end

  local counter = 0
  for i = s, e, d do
    local token, delim = get_segment_parts(data.segments[i], data.bufnr)

    if data.converted < data.count then
      local idx = (counter % #input) + 1
      local new_delim = input:sub(idx, idx)
      if new_delim ~= delim then
        delim = new_delim
        data.converted = data.converted + 1
      end
    end
    counter = counter + 1

    local segment = token .. delim
    data.new_sig = from_start and (data.new_sig .. segment) or (segment .. data.new_sig)
  end

  -- make edit
  submit_heading_change(data)
end

function FeyMappings:anonymize_or_enumerate_full_heading(enumerate)
  local data = setup_heading_func(self)
  local s, e, d = setup_reversible_loop(true, #data.segments)
  data.count = data.level

  for i = s, e, d do
    local token, delim = get_segment_parts(data.segments[i], data.bufnr)

    local enumerated = token ~= ''
    local convert = (enumerate and not enumerated) or (not enumerate and enumerated)

    if convert and data.converted < data.count then
      data.converted = data.converted + 1
      if enumerate then
        token = enumerate_segment(data, true)
      else
        token = ''
      end
    end
    local segment = token .. delim
    data.new_sig = data.new_sig .. segment
  end

  -- make edit
  submit_heading_change(data)

  -- reindex buffer
  local feyfile = FeyFile:new({ filename = vim.api.nvim_buf_get_name(data.bufnr), buf = data.bufnr })
  EventManager.dispatch(events.BufferChanged:new(feyfile))
end

---@param enumerate boolean
---@param from_start boolean
function FeyMappings:anonymize_or_enumerate_heading(enumerate, from_start)
  local data = setup_heading_func(self)
  local s, e, d = setup_reversible_loop(from_start, #data.segments)

  for i = s, e, d do
    local token, delim = get_segment_parts(data.segments[i], data.bufnr)

    local enumerated = token ~= ''
    local convert = (enumerate and not enumerated) or (not enumerate and enumerated)

    if convert and data.converted < data.count then
      data.converted = data.converted + 1
      if enumerate then
        token = enumerate_segment(data, from_start)
      else
        token = ''
      end
    end
    local segment = token .. delim
    data.new_sig = from_start and (data.new_sig .. segment) or (segment .. data.new_sig)
  end

  -- make edit
  submit_heading_change(data)

  -- reindex buffer
  local feyfile = FeyFile:new({ filename = vim.api.nvim_buf_get_name(data.bufnr), buf = data.bufnr })
  EventManager.dispatch(events.BufferChanged:new(feyfile))
end

function FeyMappings:reindex_heading_or_list()
  local node = ts_utils.closest_item_or_heading_node()
  if not node then return end
  local bufnr = vim.api.nvim_get_current_buf()
  local feyfile = FeyFile:new({ filename = vim.api.nvim_buf_get_name(bufnr), buf = bufnr })
  if node:type() == 'heading' then
    EventManager.dispatch(events.BufferChanged:new(feyfile))
  else
    EventManager.dispatch(events.BufferChanged:new(feyfile, true))
  end
end

function FeyMappings:fix_indentation()
  local node = assert(ts_utils.closest_item_heading_or_rootbody_node())

  local node_type = node:type()
  local start_line, end_line
  if node_type == 'heading' then
    local parent_section = assert(node:parent())
    local parent_first_child = parent_section:field('subsection')[1]
    start_line = node:start() + 1
    end_line = parent_first_child and parent_first_child:start() or parent_section:end_()
  elseif node_type == 'listitem' then
    local parent_list = assert(node:parent())
    start_line = parent_list:start()
    end_line = parent_list:end_()
  else
    start_line = node:start()
    end_line = node:end_()
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line, end_line, false)
  for i, line in ipairs(lines) do
    line, _ = line:gsub('^%s+', '')
    local is_empty = line:match('^$')
    local indent_amount = is_empty and 0 or indent.indentexpr(start_line + i, bufnr)
    lines[i] = string.rep(' ', indent_amount) .. line
  end

  vim.api.nvim_buf_set_lines(bufnr, start_line, end_line, false, lines)
end

function FeyMappings:fey_return()
  local actions = {
    function()
      local tbl = Table.from_current_node()
      return tbl and tbl:handle_cr() or false
    end,
    function()
      if not config.mappings.fey_return_uses_meta_return then return false end

      if vim.trim(vim.fn.getline('.'):sub(vim.fn.col('.'), vim.fn.col('$'))) ~= '' then return false end

      return self:meta_return()
    end,
  }

  for _, action in ipairs(actions) do
    local handled = action()
    if handled then return end
  end

  local global_cr_keymap = utils.get_keymap({
    mode = 'i',
    lhs = '<CR>',
  })

  if not global_cr_keymap or vim.tbl_isempty(global_cr_keymap) then
    return vim.api.nvim_feedkeys(utils.esc('<CR>'), 'n', true)
  end

  local function get_rhs()
    if global_cr_keymap.callback then
      local result = global_cr_keymap.callback()
      if global_cr_keymap.expr == 0 or not result then return end
      return vim.api.nvim_replace_termcodes(result, true, true, true)
    end

    if global_cr_keymap.expr > 0 then
      -- expr rhs: the string is a Vimscript expression, eval it first
      local ok, result = pcall(vim.api.nvim_eval, global_cr_keymap.rhs)
      if ok then return vim.api.nvim_replace_termcodes(result, true, true, true) end
    end

    return vim.api.nvim_replace_termcodes(global_cr_keymap.rhs, true, true, true)
  end

  local rhs = get_rhs()
  if rhs then return vim.api.nvim_feedkeys(rhs, 'n', true) end
end

function FeyMappings:handle_return(suffix)
  vim.deprecate('fey_mappings.handle_return', 'fey_mappings.meta_return', '0.4', 'fey', false)
  return self:meta_return(suffix)
end

local function get_new_signature(data)
  local count, signature, level = unpack(data)
  local bufnr = vim.api.nvim_get_current_buf()
  local new_signature = ''
  for i = 1, count do
    local token, delimiter
    if (signature and level) and i <= level then
      token, delimiter = get_segment_parts(signature:named_children()[i], bufnr)
    else
      local pattern_idx = ((i - 1) % #config.fey_default_subheading_index_order) + 1
      local pattern = config.fey_default_subheading_index_order[pattern_idx]
      token = sequences.patterns[pattern].to_symbol(1)
      local delim_idx = ((i - 1) % #config.fey_default_subheading_delimiter_order) + 1
      delimiter = config.fey_default_subheading_delimiter_order:sub(delim_idx, delim_idx)
      delimiter = delimiter ~= '' and delimiter or config.fey_default_subheading_delimiter
    end
    local segment = token .. delimiter
    new_signature = new_signature .. segment
  end

  return new_signature
end

---@param subheading boolean?
function FeyMappings:meta_return(suffix, subheading)
  suffix = suffix or ''
  local item = ts_utils.closest_item_or_heading_node()

  if not item then
    self:_insert_heading_from_plain_line(suffix, subheading)
    return vim.cmd([[startinsert!]])
  elseif item:type() == 'heading' then
    local linenr = vim.fn.line('.') or 0
    local signature = assert(item:field('signature')[1])
    local level = signature and signature:named_child_count()
    local count = subheading and (level + vim.v.count1) or (vim.v.count > 0 and vim.v.count or level)

    local new_signature = '  ' .. get_new_signature({ count, signature, level })
    local content = config:respect_blank_before_new_entry({ new_signature .. ' ' .. suffix })
    vim.fn.append(linenr, content)
    vim.fn.cursor(linenr + #content, 1)
    vim.cmd([[startinsert!]])
    return true
  end

  -- item is a listitem here
  return self:_insert_item_below(item, subheading)
end

---@private
---@param listitem TSNode
---@param subheading boolean?
function FeyMappings:_insert_item_below(listitem, subheading)
  local srow, _, end_row, end_col = listitem:range()
  local is_multiline = (end_row - srow) > 1 or end_col == 0

  -- For last item in file, ts grammar is not parsing the end column as 0
  -- while in other cases end column is always 0
  local is_last_item_in_file = end_col ~= 0
  if not is_multiline or is_last_item_in_file then end_row = end_row + 1 end

  local range = {
    start = { line = end_row, character = 0 },
    ['end'] = { line = end_row, character = 0 },
  }

  local bullet_node = listitem:field('bullet')[1]
  local segment = bullet_node:named_child(0)
  if not segment then return end
  local token_node = segment:child(0)
  local delim_node = segment:child(1)
  if not (token_node and delim_node) then return end

  local token_text = vim.treesitter.get_node_text(token_node, 0) or ''
  local delim_text = vim.treesitter.get_node_text(delim_node, 0) or ''
  local is_ordered = token_text ~= ''

  local _, indent_len = segment:start()
  if subheading then indent_len = indent_len + vim.fn.shiftwidth() end
  local indent_str = string.rep(' ', indent_len)

  local spacing = '  '

  local text_edits = config:respect_blank_before_new_entry({}, 'list_item', {
    range = range,
    newText = '\n',
  })
  local add_empty_line = #text_edits > 0

  if not is_ordered then
    table.insert(text_edits, {
      range = range,
      newText = indent_str .. delim_text .. spacing .. '\n',
    })
  else
    local _, list_depth = ts_utils.closest_root_list_node()
    local pattern_idx = ((list_depth - 1) % #config.fey_default_sublist_index_order) + 1
    local pattern = config.fey_default_sublist_index_order[pattern_idx]
    local next_symbol = sequences.patterns[pattern].to_symbol(1)

    -- If creating a subheading, reset the counter to 1 for the new sub-list

    table.insert(text_edits, {
      range = range,
      newText = indent_str .. next_symbol .. delim_text .. spacing .. '\n',
    })

    -- TODO: Re-number subsequent siblings (only if NOT creating a new subheading level)
  end

  if #text_edits > 0 then
    vim.lsp.util.apply_text_edits(text_edits, vim.api.nvim_get_current_buf(), constants.default_offset_encoding)

    -- if checkbox then
    --   local new_listitem = self.files:get_closest_listitem()
    --   if new_listitem then
    --     new_listitem:update_checkbox('off')
    --   end
    -- end

    -- +1 for next line, go to end of line with arbitrary big column number
    vim.fn.cursor(end_row + 1 + (add_empty_line and 1 or 0), 99999)

    vim.cmd([[startinsert!]])
    return true
  end
end

---@param subheading boolean?
function FeyMappings:insert_heading_respect_content(suffix, subheading)
  suffix = suffix or ''
  local item = self.files:get_closest_heading_or_nil()
  if not item then
    self:_insert_heading_from_plain_line(suffix)
  else
    local signature = item:get_child_node('signature')
    local level = item:get_level()
    local count = subheading and (level + vim.v.count1) or (vim.v.count > 0 and vim.v.count or level)
    local new_signature = '  ' .. get_new_signature({ count, signature, level })
    local line = config:respect_blank_before_new_entry({ new_signature .. ' ' .. suffix })
    local end_line = item:get_range().end_line
    vim.fn.append(end_line, line)
    vim.fn.cursor(end_line + #line, 1)
  end
  return vim.cmd([[startinsert!]])
end

---@param subheading boolean?
function FeyMappings:insert_todo_heading_respect_content(subheading)
  local todo_keywords = self.files:get_current_file():get_todo_keywords()
  return self:insert_heading_respect_content(todo_keywords:first_by_type('TODO').value .. ' ', subheading)
end

---@param subheading boolean?
function FeyMappings:insert_todo_heading(subheading)
  local item = self.files:get_closest_heading_or_nil()
  local todo_keywords = self.files:get_current_file():get_todo_keywords()
  local first_todo_keyword = todo_keywords:first_by_type('TODO')
  if not item then
    self:_insert_heading_from_plain_line(first_todo_keyword.value .. ' ', subheading)
    return vim.cmd([[startinsert!]])
  else
    vim.fn.cursor(item:get_range().start_line, 1)
    return self:meta_return(first_todo_keyword.value .. ' ', subheading)
  end
end

---@param subheading boolean?
function FeyMappings:_insert_heading_from_plain_line(suffix, subheading)
  suffix = suffix or ''
  local linenr = vim.fn.line('.') or 0
  local line = vim.fn.getline(linenr)
  local count = subheading and (1 + vim.v.count1) or (vim.v.count > 0 and vim.v.count or 1)
  local heading_signature = '  ' .. get_new_signature({ count }) .. ' '

  if #line == 0 then
    line = heading_signature
    vim.fn.setline(linenr, line)
    vim.fn.cursor(linenr, 0 + #line)
  else
    if vim.fn.col('.') == 1 then
      -- promote whole line to heading
      line = heading_signature .. line
      vim.fn.setline(linenr, line)
      vim.fn.cursor(linenr, 0 + #line)
    else
      -- split at cursor
      local left = string.sub(line, 0, vim.fn.col('.') - 1)
      local right = string.sub(line, vim.fn.col('.') or 0, #line)
      line = heading_signature .. right
      vim.fn.setline(linenr, left)
      vim.fn.append(linenr, line)
      vim.fn.cursor(linenr + 1, 0 + #line)
    end
  end
end

-- Inserts a new link after the cursor position or modifies the link the cursor is
-- currently on
function FeyMappings:insert_link()
  local link = FeyHyperlink.at_cursor()
  return Input.open(
    'Links: ',
    link and link.url:to_string() or '',
    function(arg_lead) return self.completion:complete_links_from_input(arg_lead) end
  ):next(function(link_location)
    if not link_location then return false end

    if vim.trim(link_location) == '' then
      utils.echo_warning('No Link selected')
      return false
    end

    return self.links:insert_link(link_location, link and link.desc)
  end)
end

function FeyMappings:store_link()
  local heading = self.files:get_closest_heading()
  self.links:store_link_to_heading(heading)
  return utils.echo_info('Stored: ' .. heading:get_title())
end

function FeyMappings:move_subtree_up()
  local item = self.files:get_closest_heading()
  local prev_heading = item:get_prev_heading_same_level()
  if not prev_heading then return utils.echo_warning('Cannot move past superior level.') end
  local range = item:get_range()
  local target_line = prev_heading:get_range().start_line - 1
  local foldclosed = vim.fn.foldclosed('.')
  vim.cmd(string.format(':%d,%dmove %d', range.start_line, range.end_line, target_line))
  local pos = vim.fn.getcurpos()
  vim.fn.cursor(target_line + 1, pos[3])
  if foldclosed > -1 and vim.fn.foldlevel('.') > 0 and vim.fn.foldclosed('.') == -1 then vim.cmd([[norm!zc]]) end
  EventManager.dispatch(events.HeadingPromoted:new(self.files:get_closest_heading(), item:get_level()))
end

function FeyMappings:move_subtree_down()
  local item = self.files:get_closest_heading()
  local next_heading = item:get_next_heading_same_level()
  if not next_heading then return utils.echo_warning('Cannot move past superior level.') end
  local range = item:get_range()
  local target_line = next_heading:get_range().end_line
  local foldclosed = vim.fn.foldclosed('.')
  vim.cmd(string.format(':%d,%dmove %d', range.start_line, range.end_line, target_line))
  local pos = vim.fn.getcurpos()
  vim.fn.cursor(target_line + range.start_line - range.end_line, pos[3])
  if foldclosed > -1 and vim.fn.foldlevel('.') > 0 and vim.fn.foldclosed('.') == -1 then vim.cmd([[norm!zc]]) end
  EventManager.dispatch(events.HeadingPromoted:new(self.files:get_closest_heading(), item:get_level()))
end

function FeyMappings:show_help(type) return Help.show(type) end

function FeyMappings:edit_special()
  local edit_special = EditSpecial:new()
  edit_special:init_in_fey_buffer()
  edit_special:init()
end

function FeyMappings:_edit_special_callback() EditSpecial:new():done() end

function FeyMappings:add_note()
  local heading = self.files:get_closest_heading()
  local indent = heading:get_indent()
  local text = ('%s- Note taken on %s \\\\'):format(indent, Date.now():to_wrapped_string(false))
  return self:_get_note(text, indent, string.format('Insert note for %s.', heading:get_title() or 'entry')):next(function(note)
    if not note then return false end
    return heading:add_note(note)
  end)
end

function FeyMappings:open_at_point()
  local link = FeyHyperlink.at_cursor()

  if link then return self.links:follow(link.url:to_string()) end

  local date = self:_get_date_under_cursor()
  if date then return self.agenda:open_day(date) end

  local footnote = Footnote.at_cursor()
  if footnote then
    if footnote.is_reference then return self:_jump_to_footnote_definition(footnote) end
    return self:_jump_to_footnote_reference(footnote)
  end
end

function FeyMappings:_jump_to_footnote_reference(footnote_definition)
  local file = self.files:get_current_file()
  local reference = file:find_footnote_reference(footnote_definition)

  if not reference then
    return utils.echo_info(('Cannot find reference for footnote "%s"'):format(footnote_definition:get_name()))
  end

  return vim.fn.cursor({ reference.range.start_line, reference.range.start_col })
end

---@param footnote_reference FeyFootnote
function FeyMappings:_jump_to_footnote_definition(footnote_reference)
  local file = self.files:get_current_file()
  local footnote = file:find_footnote_definition(footnote_reference)

  if not footnote then
    local choice = vim.fn.confirm('No footnote found. Create one?', '&Yes\n&No')
    if choice ~= 1 then return end

    local footnotes_heading = file:find_heading_by_title('footnotes')
    local fndef = ('[fn:%s] '):format(footnote_reference.label)
    if footnotes_heading then
      local append_line = footnotes_heading:get_append_line()
      vim.api.nvim_buf_set_lines(0, append_line, append_line, false, { fndef })
      vim.fn.cursor({ append_line + 1, #fndef })
      return vim.cmd('startinsert!')
    end
    local last_line = vim.api.nvim_buf_line_count(0)
    vim.api.nvim_buf_set_lines(0, last_line, last_line, false, { '', '* Footnotes', fndef })
    vim.fn.cursor({ last_line + 3, #fndef })
    return vim.cmd('startinsert!')
  end

  return vim.fn.cursor({ footnote.range.start_line, footnote.range.start_col })
end

function FeyMappings:export() return require('fey.export').prompt() end

---Find and move cursor to next visible heading.
---@return integer
function FeyMappings:next_visible_heading() return vim.fn.search([[^\*\+\s\+]], 'W', 0, 0, self._skip_invisible_heading) end

---Find and move cursor to previous visible heading.
---@return integer
function FeyMappings:previous_visible_heading() return vim.fn.search([[^\*\+\s\+]], 'bW', 0, 0, self._skip_invisible_heading) end

---Check if heading is visible. If not, skip it.
---@return integer
function FeyMappings:_skip_invisible_heading()
  local fold = vim.fn.foldclosed('.')
  if fold == -1 or vim.fn.line('.') == fold then return 0 end
  return 1
end

function FeyMappings:forward_heading_same_level()
  local item = self.files:get_closest_heading()
  local next_heading_same_level = item:get_next_heading_same_level()
  if not next_heading_same_level then return end
  return vim.fn.cursor(next_heading_same_level:get_range().start_line, 1)
end

function FeyMappings:backward_heading_same_level()
  local item = self.files:get_closest_heading()
  local prev_heading_same_level = item:get_prev_heading_same_level()
  if not prev_heading_same_level then return end
  return vim.fn.cursor(prev_heading_same_level:get_range().start_line, 1)
end

function FeyMappings:outline_up_heading()
  local item = self.files:get_closest_heading()
  local parent = item:get_parent_heading()
  if not parent then return utils.echo_info('Already at top level of the outline') end
  return vim.fn.cursor(parent:get_range().start_line, 1)
end

function FeyMappings:fey_deadline()
  local heading = self.files:get_closest_heading()
  local deadline_date = heading:get_deadline_date()
  return Calendar.new({ date = deadline_date or Date.today(), clearable = true, title = 'Set deadline' })
    :open()
    :next(function(new_date, cleared)
      if cleared then return heading:remove_deadline_date() end
      if not new_date then return nil end
      heading:remove_closed_date()
      heading:set_deadline_date(new_date)
    end)
end

function FeyMappings:fey_schedule()
  local heading = self.files:get_closest_heading()
  local scheduled_date = heading:get_scheduled_date()
  return Calendar.new({ date = scheduled_date or Date.today(), clearable = true, title = 'Set schedule' })
    :open()
    :next(function(new_date, cleared)
      if cleared then return heading:remove_scheduled_date() end
      if not new_date then return nil end
      heading:remove_closed_date()
      heading:set_scheduled_date(new_date)
    end)
end

---@param inactive boolean
function FeyMappings:fey_time_stamp(inactive)
  local date = self:_get_date_under_cursor()

  if date then
    return Calendar.new({ date = date, title = 'Replace date' }):open():next(function(new_date)
      if not new_date then return end
      self:_replace_date(new_date)
    end)
  end

  local date_start = self:_get_date_under_cursor(-1)

  return Calendar.new({ date = Date.today() }):open():next(function(new_date)
    if not new_date then return nil end
    local date_string = new_date:to_wrapped_string(not inactive)
    if date_start then
      date_string = '--' .. date_string
      vim.cmd('norm!x')
    end
    vim.cmd(string.format('norm!a%s', date_string))
  end)
end

function FeyMappings:fey_toggle_timestamp_type()
  local date = self:_get_date_under_cursor()
  if not date then return end

  date.active = not date.active
  self:_replace_date(date)
end

---@param direction string
---@param use_fast_access? boolean
---@return boolean
function FeyMappings:_change_todo_state(direction, use_fast_access)
  local heading = self.files:get_closest_heading()
  local current_keyword = heading:get_todo() or ''

  local todos = heading.file:get_todo_keywords()

  local todo_state = TodoState:new({ current_state = current_keyword, todos = todos })
  local next_state = nil

  if use_fast_access and todo_state:has_fast_access() then
    next_state = todo_state:open_fast_access()
  else
    if direction == 'next' then
      next_state = todo_state:get_next()
    elseif direction == 'prev' then
      next_state = todo_state:get_prev()
    end
  end

  if not next_state then return false end

  if next_state.value == current_keyword then
    if current_keyword ~= '' then
      utils.echo_info('TODO state was already ', { {
        next_state.value,
        next_state.hl,
      } })
    end
    return false
  end

  heading:set_todo(next_state.value)
  return true
end

---@param date FeyDate
function FeyMappings:_replace_date(date)
  local line = vim.fn.getline(date.range.start_line)
  local view = vim.fn.winsaveview() or {}
  vim.fn.setline(
    date.range.start_line,
    string.format('%s%s%s', line:sub(1, date.range.start_col - 1), date:to_wrapped_string(), line:sub(date.range.end_col + 1))
  )
  vim.fn.winrestview(view)
  return true
end

---@return FeyDate|nil
function FeyMappings:_get_date_under_cursor(col_offset)
  col_offset = col_offset or 0
  local col = vim.fn.col('.') + col_offset
  local line = vim.fn.line('.') or 0
  local item = self.files:get_closest_heading_or_nil()
  local dates = {}
  if item then
    dates = item:get_all_dates()
  else
    dates = Date.from_node(ts_utils.closest_node(ts_utils.get_node(), 'timestamp'))
  end

  local valid_dates = vim.tbl_filter(function(date) return date.range:is_in_range(line, col) end, dates)
  return valid_dates[1]
end

---@param amount number
---@param span string
---@param fallback string
function FeyMappings:_adjust_date(amount, span, fallback)
  local adjustment = string.format('%s%d%s', amount > 0 and '+' or '', amount, span)
  local date = self:_get_date_under_cursor()
  if date then
    local new_date = date:adjust(adjustment)
    return self:_replace_date(new_date)
  end

  local is_count_mapping = vim.tbl_contains({ '<c-a>', '<c-x>' }, fallback:lower())
  if not is_count_mapping then return vim.api.nvim_feedkeys(utils.esc(fallback), 'n', true) end

  local num = vim.fn.search([[\d]], 'c', vim.fn.line('.'))
  if num == 0 then return vim.api.nvim_feedkeys(utils.esc(fallback), 'n', true) end

  date = self:_get_date_under_cursor()
  if date then
    local new_date = date:adjust(adjustment)
    return self:_replace_date(new_date)
  end

  return vim.api.nvim_feedkeys(utils.esc(fallback), 'n', true)
end

---@param heading FeyHeading
function FeyMappings:_goto_heading(heading)
  local current_file_path = utils.current_file_path()
  if heading.file.filename ~= current_file_path then
    vim.cmd(string.format('edit %s', heading.file.filename))
  else
    vim.cmd([[normal! m']]) -- add link source to jumplist
  end
  vim.fn.cursor({ heading:get_range().start_line, 1 })
  vim.cmd([[normal! zv]])
end

return FeyMappings
