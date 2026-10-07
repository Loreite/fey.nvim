local Calendar = require('fey.objects.calendar')
local Date = require('fey.objects.date')
local EditSpecial = require('fey.objects.edit_special')
local Help = require('fey.objects.help')
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
local sequences = require('fey.utils.sequences')
local FeyFile = require('fey.files.file')
local tableops = require('fey.files.elements.table.operations')

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
---@field completion FeyCompletion
local FeyMappings = {}

---@param data table
function FeyMappings:new(data)
  local opts = {}
  opts.global_cycle_mode = 'all'
  opts.capture = data.capture
  opts.agenda = data.agenda
  opts.files = data.files
  opts.completion = data.completion
  setmetatable(opts, self)
  self.__index = self
  return opts
end

-- TODO:
-- Support archiving to heading
function FeyMappings:archive() return require('fey.refile').archive_at_cursor() end

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
          function(arg_lead) return utils.prompt_autocomplete(arg_lead, require('fey.agenda.source').new():labels()) end
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

---Does the section have anything to fold?
---@param section TSNode
local function is_expandable(section)
  if #section:field('subsection') > 0 then return true end
  local body = section:field('body')[1]
  return body ~= nil and vim.treesitter.get_node_text(body, 0):find('%S') ~= nil
end

---Toggle the fold under the cursor. On a heading it cycles like org-mode: a closed section
---opens (children stay folded), an open one with open children folds those first, otherwise
---it closes. On the head or closer of a block or pair tag, or inside its body, it toggles the
---fold of the tag.
function FeyMappings:cycle()
  local bufnr = vim.api.nvim_get_current_buf()
  local line = vim.fn.line('.') or 0
  if not vim.wo.foldenable then
    vim.wo.foldenable = true
    vim.cmd([[silent! norm!zx]])
  end

  local folds = require('fey.fey.folds')
  local tag = folds.tag_at_line(bufnr, line)
  if tag then return folds.apply(tag, 'za') end

  if vim.fn.foldlevel(line) == 0 then return utils.echo_info('No fold') end
  if vim.fn.foldclosed(line) ~= -1 then return vim.cmd([[silent! norm!zo]]) end

  ts_utils.parse_current_file()
  local section = ts_utils.closest_node(ts_utils.get_node_at_cursor({ line, 0 }), 'section')
  if not section then return end
  if not is_expandable(section) then return end

  local children = section:field('subsection')
  local close = #children == 0

  if not close then
    local has_nested_children = false
    for _, child in ipairs(children) do
      local expandable = is_expandable(child)
      if expandable then has_nested_children = true end
      local child_line = child:start() + 1
      if expandable and vim.fn.foldclosed(child_line) == -1 then
        vim.cmd(string.format('silent! keepjumps norm!%dggzc', child_line))
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

function FeyMappings:fey_babel_tangle_vault() return Babel.tangle_scope('current') end

function FeyMappings:fey_babel_check() return Babel.check('current') end

function FeyMappings:toggle_checkbox()
  local win_view = vim.fn.winsaveview() or {}
  -- move to the first non-blank character so the current treesitter node is the listitem
  vim.cmd([[normal! _]])

  local listitem = self.files:get_closest_listitem()
  if listitem then listitem:update_checkbox('toggle') end

  vim.fn.winrestview(win_view)
end

---Pick the state of the checkbox of the item under the cursor from the list of states
function FeyMappings:set_checkbox_state()
  local Checkbox = require('fey.files.elements.checkbox')
  local style = require('fey.colors.highlighter.checkbox_icons').style()
  local win_view = vim.fn.winsaveview() or {}
  vim.cmd([[normal! _]])
  local row = vim.fn.line('.')
  local states = vim.tbl_filter(function(state) return state.mark ~= 'X' end, Checkbox.STATES)
  vim.ui.select(states, {
    prompt = 'Checkbox state',
    format_item = function(state)
      return ('%s [%s] %s (%s)'):format(Checkbox.icon(state.mark, style), state.mark, state.name, state.class)
    end,
  }, function(choice)
    if not choice then return end
    vim.fn.cursor({ row, 1 })
    vim.cmd([[normal! _]])
    local listitem = self.files:get_closest_listitem()
    if listitem then listitem:update_checkbox('mark:' .. choice.mark) end
    vim.fn.winrestview(win_view)
  end)
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
    if col < date.range.start_col or col > date.range.end_col then return false end
    -- the range is the text of the date itself, parts are counted from 1
    local col_from_start = col - date.range.start_col + 1
    local parts = date:parse_parts()
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

---@type fun(data: table): string defined with the other helpers of headings, below
local get_new_signature

---Turn the line under the cursor into a heading, or a heading into plain text (`fey_toggle_heading`)
---
---   a heading             becomes its title as plain text
---   a list item           becomes a heading under the heading above it; its checkbox becomes a status tag
---   any other line        becomes a heading under the heading above it
---
---The signature is the next one at that level; the headings below are renumbered.
function FeyMappings:toggle_heading()
  local bufnr = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ''
  local file = self.files:get_current_file()
  local heading = self.files:get_closest_heading_or_nil()

  local function finish(action)
    EventManager.dispatch(events.HeadingToggled:new(row, action, self.files:get_closest_heading_or_nil({ row, 0 })))
    EventManager.dispatch(events.BufferChanged:new(FeyFile:new({ filename = vim.api.nvim_buf_get_name(bufnr), buf = bufnr })))
  end

  -- a heading: its title as plain text
  if heading and heading:get_range().start_line == row then
    local title = heading:get_child_node('title')
    vim.api.nvim_buf_set_lines(bufnr, row - 1, row, false, { title and file:get_node_text(title) or '' })
    return finish('heading_to_line')
  end

  -- what the new heading says: the text of the line, without the bullet and the checkbox of a list item
  local text = line:gsub('^%s+', '')
  local status
  local item = self.files:get_closest_listitem()
  local item_node = item and item.listitem
  if item_node and item_node:start() == row - 1 then
    local bullet = item_node:field('bullet')[1]
    if bullet then
      local _, _, _, bullet_end = bullet:range()
      text = line:sub(bullet_end + 1):gsub('^%s+', '')
      local mark, rest = text:match('^%[(.)%]%s*(.*)$')
      if mark then
        text = rest
        local keywords = file:get_todo_keywords()
        if mark == 'x' or mark == 'X' then
          status = keywords:first_by_type('DONE').value
        elseif mark == ' ' then
          status = keywords:first_by_type('TODO').value
        end
      end
    end
  end

  local level = heading and heading:get_level() or 0
  local signature = heading and heading:get_child_node('signature') or nil
  local new_signature = get_new_signature({ level + 1, signature, level })
  local tag = status and ('{# status, %s #} '):format(status) or ''
  vim.api.nvim_buf_set_lines(bufnr, row - 1, row, false, { ('  %s %s%s'):format(new_signature, tag, text) })
  return finish(heading and 'line_to_child_heading' or 'line_to_heading')
end

---The first line of a note: a list item with an inactive date, then what kind of note it is
---@param what string for example `Note taken:`
---@return string
local function note_head(what) return ('-  %s  %s'):format(Date.now():to_tag_text({ active = false }), what) end

---Prompt for a note and make it a list item: the head, with the first line of the text after it, and the other
---lines indented under it
---@private
---@param head string see `note_head`
---@param title string title of the prompt
---@return FeyPromise<string[]>
function FeyMappings:_get_note(head, title)
  return self.capture:build_note_capture(title):open():next(function(text)
    if text == nil then return end
    local lines = { vim.trim(head .. ' ' .. (text[1] or '')) }
    for i = 2, #text do
      lines[#lines + 1] = text[i] ~= '' and ('   ' .. text[i]) or ''
    end
    return lines
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
  local closing_head = note_head('Closing note:')
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

    return self:_get_note(closing_head, closed_title):next(function(closing_note) return item:add_note(closing_note) end)
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
  local repeat_note_template = note_head(('State "%s" from "%s"'):format(new_todo, old_state or ''))
  local repeat_note_title = ('Insert note for state change from "%s" to "%s"'):format(old_state or '', new_todo)

  if log_repeat_enabled then item:set_property('LAST_REPEAT', Date.now():to_wrapped_string(false)) end

  if not prompt_repeat_note and not prompt_done_note then
    -- If user is not prompted for a note, use a default repeat note
    if log_repeat_enabled then return item:add_note({ repeat_note_template }) end
    return item
  end

  -- Done note has precedence over repeat note
  if prompt_done_note then
    return self:_get_note(closing_head, closed_title):next(function(closing_note) return item:add_note(closing_note) end)
  end

  return self
    :_get_note(repeat_note_template, repeat_note_title)
    :next(function(closing_note) return item:add_note(closing_note) end)
end

function FeyMappings:do_promote(whole_subtree)
  local count = vim.v.count1
  local win_view = vim.fn.winsaveview() or {}
  -- move to the first non-blank character so the current treesitter node is the listitem
  vim.cmd([[normal! _]])

  local node = ts_utils.get_node_at_cursor()
  local set = utils.set({ 'listitem', 'bullet', 'segment', 'list' })
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
  local set = utils.set({ 'listitem', 'bullet', 'segment', 'list' })
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

function FeyMappings:change_list_delimiters()
  local listitem = self.files:get_closest_listitem()
  if not listitem then return end
  local list = assert(listitem.listitem:parent())
  local bufnr = vim.api.nvim_get_current_buf()

  local input = vim.fn.input('Delimiter: ')
  input = input:gsub('[^.,:;!?/\\\'"`%-+*=~^@&#$%%%[%](){}<>]', '')
  if input == '' then return end

  local edits = {}
  local counter = 0
  for _, item in ipairs(list:named_children()) do
    if item:type() == 'listitem' then
      local bullet = item:field('bullet')[1]
      local segment = bullet and bullet:named_child(0)
      local delim_node = segment and segment:child(1)
      if delim_node then
        local idx = (counter % #input) + 1
        local new_delim = input:sub(idx, idx)
        counter = counter + 1
        if vim.treesitter.get_node_text(delim_node, bufnr) ~= new_delim then
          table.insert(edits, { r = { delim_node:range() }, text = new_delim })
        end
      end
    end
  end

  for i = #edits, 1, -1 do
    local e = edits[i]
    vim.api.nvim_buf_set_text(bufnr, e.r[1], e.r[2], e.r[3], e.r[4], { e.text })
  end

  -- trigger reindex
  local feyfile = FeyFile:new({ filename = vim.api.nvim_buf_get_name(bufnr), buf = bufnr })
  EventManager.dispatch(events.BufferChanged:new(feyfile, true))
end

function FeyMappings:anonymize_or_enumerate_full_heading(enumerate)
  local data = setup_heading_func(self)
  local s, e, d = setup_reversible_loop(true, #data.segments)
  data.count = data.level

  for i = s, e, d do
    local token, delim = get_segment_parts(data.segments[i], data.bufnr)

    local anon, enum = token:match(constants.segment_enumeration)
    if not anon then
      anon = ''
      enum = token
    end

    local enumerated = enum ~= ''
    local convert = (enumerate and not enumerated) or (not enumerate and enumerated)

    if convert and data.converted < data.count then
      data.converted = data.converted + 1
      if enumerate then
        token = anon .. enumerate_segment(data, true)
      else
        token = anon
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

    local anon, enum = token:match(constants.segment_enumeration)
    if not anon then
      anon = ''
      enum = token
    end

    local enumerated = enum ~= ''
    local convert = (enumerate and not enumerated) or (not enumerate and enumerated)

    if convert and data.converted < data.count then
      data.converted = data.converted + 1
      if enumerate then
        token = anon .. enumerate_segment(data, from_start)
      else
        token = anon
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

  -- Check if we are inside a standard paragraph node
  local node = vim.treesitter.get_node()
  if node and node:type() == 'paragraph' then
    if node:parent() and node:parent():type() == 'listitem' then goto breakout end
    local current_line = vim.api.nvim_get_current_line()
    local indent_pad = current_line:match('^(%s*)') or ''

    -- Feed <CR> followed by the previous line's exact leading indent
    local keys = vim.api.nvim_replace_termcodes('<CR>' .. indent_pad, true, true, true)
    return vim.api.nvim_feedkeys(keys, 'n', true)
  end
  ::breakout::

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

get_new_signature = function(data)
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

---@param alternate boolean?
function FeyMappings:meta_return(suffix, alternate)
  suffix = suffix or ''

  -- Handle table cell context first
  local tbl, r, c = tableops.get_ctx()
  if tbl then
    local active_cell = nil
    for _, cl in ipairs(tbl.rows[r].cells) do
      if cl.col_idx <= c and (cl.col_idx + cl.colspan - 1) >= c then
        active_cell = cl
        break
      end
    end

    -- Resolve vertical merge shadow cells back to their root cell
    if active_cell and active_cell.rowspan == 0 then
      for root_r = r - 1, 1, -1 do
        for _, root_c in ipairs(tbl.rows[root_r].cells) do
          if root_c.col_idx <= c and (root_c.col_idx + root_c.colspan - 1) >= c and root_c.rowspan > 0 then
            active_cell = root_c
            break
          end
        end
        if active_cell and active_cell.rowspan > 0 then break end
      end
    end

    if active_cell then
      if #active_cell.lines > 1 then
        tableops.table_cell_line_flatten(alternate)
      else
        tableops.table_cell_content_merge('vertical', alternate)
      end
      return true
    end
  end

  local item = ts_utils.closest_item_or_heading_node()

  if not item then
    self:_insert_heading_from_plain_line(suffix, alternate)
    return vim.cmd([[startinsert!]])
  elseif item:type() == 'heading' then
    local linenr = vim.fn.line('.') or 0
    local signature = assert(item:field('signature')[1])
    local level = signature and signature:named_child_count()
    local count = alternate and (level + vim.v.count1) or (vim.v.count > 0 and vim.v.count or level)

    local new_signature = '  ' .. get_new_signature({ count, signature, level })
    local content = config:respect_blank_before_new_entry({ new_signature .. ' ' .. suffix })
    vim.fn.append(linenr, content)
    vim.fn.cursor(linenr + #content, 1)
    vim.cmd([[startinsert!]])
    return true
  end

  -- item is a listitem here
  return self:_insert_item_below(item, alternate)
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

  local anon, enum = token_text:match(constants.segment_enumeration)
  if not anon then
    anon = ''
    enum = token_text
  end

  local is_ordered = enum ~= ''

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
      newText = indent_str .. anon .. delim_text .. spacing .. '\n',
    })
  else
    local _, list_depth = ts_utils.closest_root_list_node()
    local pattern_idx = ((list_depth - 1) % #config.fey_default_sublist_index_order) + 1
    local pattern = config.fey_default_sublist_index_order[pattern_idx]
    local next_symbol = sequences.patterns[pattern].to_symbol(1)

    -- If creating a subheading, reset the counter to 1 for the new sub-list

    table.insert(text_edits, {
      range = range,
      newText = indent_str .. anon .. next_symbol .. delim_text .. spacing .. '\n',
    })

    -- TODO: Re-number subsequent siblings (only if NOT creating a new subheading level)
  end

  if #text_edits > 0 then
    vim.lsp.util.apply_text_edits(text_edits, vim.api.nvim_get_current_buf(), constants.default_offset_encoding)

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
  return self:insert_heading_respect_content(('{# status, %s #} '):format(todo_keywords:first_by_type('TODO').value), subheading)
end

---@param subheading boolean?
function FeyMappings:insert_todo_heading(subheading)
  local item = self.files:get_closest_heading_or_nil()
  local todo_keywords = self.files:get_current_file():get_todo_keywords()
  local first_todo_keyword = todo_keywords:first_by_type('TODO')
  if not item then
    self:_insert_heading_from_plain_line(('{# status, %s #} '):format(first_todo_keyword.value), subheading)
    return vim.cmd([[startinsert!]])
  else
    vim.fn.cursor(item:get_range().start_line, 1)
    return self:meta_return(('{# status, %s #} '):format(first_todo_keyword.value), subheading)
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

-- Picks a file or a heading and writes a link tag at the cursor, over the link tag the cursor is on, or over the
-- visual selection
function FeyMappings:insert_link() return require('fey.links.insert').insert() end

function FeyMappings:store_link()
  local heading = self.files:get_closest_heading()
  require('fey.links.insert').store(heading)
  return utils.echo_info('Stored: ' .. heading:get_title())
end

function FeyMappings:check_links() return require('fey.links.check').run('current') end

---@param direction 'up'|'down'
---@return boolean handled true if the cursor is on a list item (moved or not)
function FeyMappings:_move_listitem(direction)
  vim.cmd([[normal! _]])
  local node = ts_utils.get_node_at_cursor()
  local set = utils.set({ 'listitem', 'bullet', 'segment', 'list' })
  if not (node and set[node:type()]) then return false end
  local listitem = self.files:get_closest_listitem()
  if not listitem then return false end

  if not listitem:move(direction) then
    utils.echo_warning('Cannot move past superior level.')
    return true
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local feyfile = FeyFile:new({ filename = vim.api.nvim_buf_get_name(bufnr), buf = bufnr })
  EventManager.dispatch(events.BufferChanged:new(feyfile, true))
  return true
end

---Move lines inside a buffer. Not `:move`: its range grows to the closed fold the lines are in, and a heading in a closed
---fold (the file starts folded) would be moved into itself
---@param bufnr integer
---@param first integer 1 based
---@param last integer
---@param target integer the line after which the lines go (0 for the top)
local function move_lines(bufnr, first, last, target)
  local lines = vim.api.nvim_buf_get_lines(bufnr, first - 1, last, false)
  local count = #lines
  local insert_at = target >= last and (target - count) or target
  vim.api.nvim_buf_set_lines(bufnr, first - 1, last, false, {})
  pcall(vim.cmd, 'undojoin')
  vim.api.nvim_buf_set_lines(bufnr, insert_at, insert_at, false, lines)
  return insert_at + 1
end

---Move the heading under the cursor, with what is under it, over its neighbour of the same level
---@param direction 'up'|'down'
function FeyMappings:_move_heading(direction)
  local item = self.files:get_closest_heading()
  local neighbour = direction == 'up' and item:get_prev_heading_same_level() or item:get_next_heading_same_level()
  if not neighbour then return utils.echo_warning('Cannot move past superior level.') end
  local bufnr = vim.api.nvim_get_current_buf()
  local range = item:get_range()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local offset = cursor[1] - range.start_line
  local target = direction == 'up' and (neighbour:get_range().start_line - 1) or neighbour:get_range().end_line
  local foldclosed = vim.fn.foldclosed('.')
  local at = move_lines(bufnr, range.start_line, range.end_line, target)
  vim.api.nvim_win_set_cursor(0, { at + math.max(offset, 0), cursor[2] })
  if foldclosed > -1 and vim.fn.foldlevel('.') > 0 and vim.fn.foldclosed('.') == -1 then vim.cmd([[norm!zc]]) end
  EventManager.dispatch(events.HeadingPromoted:new(self.files:get_closest_heading(), item:get_level()))
  EventManager.dispatch(events.BufferChanged:new(FeyFile:new({ filename = vim.api.nvim_buf_get_name(bufnr), buf = bufnr })))
end

function FeyMappings:move_subtree_up()
  local win_view = vim.fn.winsaveview() or {}
  if self:_move_listitem('up') then return end
  vim.fn.winrestview(win_view)
  return self:_move_heading('up')
end

function FeyMappings:move_subtree_down()
  local win_view = vim.fn.winsaveview() or {}
  if self:_move_listitem('down') then return end
  vim.fn.winrestview(win_view)
  return self:_move_heading('down')
end

function FeyMappings:show_help(type) return Help.show(type) end

function FeyMappings:edit_special()
  local edit_special = EditSpecial:new()
  edit_special:init_in_fey_buffer()
  edit_special:init()
end

function FeyMappings:_edit_special_callback() EditSpecial:new():done() end

---Prompt for a note and write it into the heading under the cursor (`fey_add_note`)
function FeyMappings:add_note()
  local heading = self.files:get_closest_heading()
  return self
    :_get_note(note_head('Note taken:'), string.format('Insert note for %s.', heading:get_title() or 'entry'))
    :next(function(note)
      if not note then return false end
      return heading:add_note(note)
    end)
end

function FeyMappings:open_at_point() return require('fey.links').open_at_cursor() end

function FeyMappings:export() return require('fey.export').prompt() end

-- ---------------------------------------------------------------------------
-- Heading navigation over the Fey AST
--
--   document := body? section*                 (field 'subsection')
--   section  := heading body? section* _end     (fields 'heading', 'body', 'subsection')
--
-- Headings are never found by text search: the cursor's section comes from
-- ts_utils.closest_heading_node(), and every move after that is a walk over
-- sibling / parent / 'subsection' links between `section` nodes.
-- ---------------------------------------------------------------------------

---Nearest `section` sibling in the given direction, skipping any non-section
---named siblings (the parent's `heading` and `body`, ERROR nodes, ...).
---@param section TSNode
---@param forward boolean
---@return TSNode|nil
local function sibling_section(section, forward)
  -- Explicit if/else, not `forward and a() or b()`: when a() returns nil
  -- that idiom falls through to b() and walks the wrong way.
  local function step(node)
    if forward then return node:next_named_sibling() end
    return node:prev_named_sibling()
  end

  local sib = step(section)
  while sib and sib:type() ~= 'section' do
    sib = step(sib)
  end
  return sib
end

---Enclosing section, or nil at the top level (parent is the document).
---@param section TSNode
---@return TSNode|nil
local function parent_section(section)
  local parent = section:parent()
  if parent and parent:type() == 'section' then return parent end
  return nil
end

---Deepest last descendant: the last heading inside `section`'s subtree.
---@param section TSNode
---@return TSNode
local function last_descendant_section(section)
  local children = section:field('subsection')
  while #children > 0 do
    section = children[#children]
    children = section:field('subsection')
  end
  return section
end

---Next section in document (pre-)order.
---@param section TSNode
---@return TSNode|nil
local function next_section_in_order(section)
  local child = section:field('subsection')[1]
  if child then return child end
  ---@type TSNode|nil
  local current = section
  while current do
    local sib = sibling_section(current, true)
    if sib then return sib end
    current = parent_section(current)
  end
  return nil
end

---Previous section in document (pre-)order.
---@param section TSNode
---@return TSNode|nil
local function prev_section_in_order(section)
  local sib = sibling_section(section, false)
  if sib then return last_descendant_section(sib) end
  return parent_section(section)
end

---1-indexed line of a section's heading.
---@param section TSNode
---@return integer
local function heading_lnum(section)
  local node = section:field('heading')[1] or section
  local row = node:start()
  return row + 1
end

---A heading is visible unless it sits inside a closed fold it does not start.
---@param lnum integer
---@return boolean
local function is_line_visible(lnum)
  local fold = vim.fn.foldclosed(lnum)
  return fold == -1 or fold == lnum
end

---@param section TSNode
---@return integer lnum
local function goto_section(section)
  local lnum = heading_lnum(section)
  vim.fn.cursor(lnum, 1)
  return lnum
end

---The section that owns the cursor, or nil in the document's root body.
---@return TSNode|nil
local function cursor_section()
  local heading = ts_utils.closest_heading_node()
  return heading and heading:parent()
end

---Find and move cursor to next visible heading.
---@return integer lnum of the heading jumped to, 0 if none
function FeyMappings:next_visible_heading()
  local section = cursor_section()
  local target
  if section then
    target = next_section_in_order(section)
  else
    -- Root body (before the first heading): the first top-level section.
    target = ts_utils.parse_current_file()[1]:root():field('subsection')[1]
  end

  while target and not is_line_visible(heading_lnum(target)) do
    target = next_section_in_order(target)
  end

  if not target then return 0 end
  return goto_section(target)
end

---Find and move cursor to previous visible heading.
---@return integer lnum of the heading jumped to, 0 if none
function FeyMappings:previous_visible_heading()
  local section = cursor_section()
  if not section then return 0 end

  -- Inside the section's body the previous heading is its own; on the
  -- heading line itself, step back one section in document order.
  ---@type TSNode|nil
  local target = section
  if vim.fn.line('.') == heading_lnum(section) then target = prev_section_in_order(section) end

  while target and not is_line_visible(heading_lnum(target)) do
    target = prev_section_in_order(target)
  end

  if not target then return 0 end
  return goto_section(target)
end

function FeyMappings:forward_heading_same_level()
  local section = cursor_section()
  local target = section and sibling_section(section, true)
  if not target then return end
  return goto_section(target)
end

function FeyMappings:backward_heading_same_level()
  local section = cursor_section()
  local target = section and sibling_section(section, false)
  if not target then return end
  return goto_section(target)
end

function FeyMappings:outline_up_heading()
  local section = cursor_section()
  local parent = section and parent_section(section)
  if not parent then return utils.echo_info('Already at top level of the outline') end
  return goto_section(parent)
end

---Jump to the last direct child heading of the section under the cursor.
function FeyMappings:last_child_heading()
  local section = cursor_section()
  if not section then return end
  local children = section:field('subsection')
  if #children == 0 then return utils.echo_info('Heading has no child headings') end
  return goto_section(children[#children])
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

---Change the date under the cursor, or insert a date tag after the cursor
---@param inactive boolean
function FeyMappings:fey_time_stamp(inactive)
  local date = self:_get_date_under_cursor()

  if date then
    return Calendar.new({ date = date, title = 'Replace date' }):open():next(function(new_date)
      if not new_date then return end
      self:_replace_date(new_date)
    end)
  end

  return Calendar.new({ date = Date.today() }):open():next(function(new_date)
    if not new_date then return nil end
    vim.api.nvim_put({ new_date:to_tag_text({ active = not inactive }) }, 'c', true, true)
  end)
end

---Show or hide the tag syntax around todo keywords, priorities and labels in headings (this buffer)
function FeyMappings:toggle_conceal_task_tags()
  local bufnr = vim.api.nvim_get_current_buf()
  local enabled = not require('fey.colors.highlighter.task_tags').enabled(bufnr)
  vim.b[bufnr].fey_conceal_task_tags = enabled
  vim.api.nvim__redraw({ buf = bufnr, valid = false })
  utils.echo_info('Task tags are ' .. (enabled and 'concealed' or 'shown'))
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

---Write a date back where it was read from: its text is replaced in place, the `active` key of its tag
---follows the date
---@param date FeyDate
function FeyMappings:_replace_date(date)
  local edit = require('fey.files.elements.tags.edit')
  local bufnr = vim.api.nvim_get_current_buf()
  local range = date.range
  local view = vim.fn.winsaveview() or {}
  vim.api.nvim_buf_set_text(
    bufnr,
    range.start_line - 1,
    range.start_col - 1,
    range.end_line - 1,
    range.end_col,
    { date:to_string() }
  )
  local tag = edit.at(bufnr, range.start_line - 1, range.start_col - 1)
  if tag then
    local default_active = date.type ~= 'CLOSED'
    local current = tag.key_values.active
    if date.active ~= default_active then
      edit.set_key(tag, 'active', tostring(date.active))
    elseif current ~= nil then
      edit.set_key(tag, 'active', nil)
    end
  end
  vim.fn.winrestview(view)
  return true
end

---The date of the date or planning tag around the cursor. In a range the end counts from its first
---character on.
---@return FeyDate|nil
function FeyMappings:_get_date_under_cursor()
  local edit = require('fey.files.elements.tags.edit')
  local col = vim.fn.col('.')
  local tag = edit.at_cursor()
  if not tag or not vim.tbl_contains(require('fey.files.elements.tags.handlers.date').names(), tag.name) then return nil end
  local dates = Date.from_tag(tag)
  if dates[2] and col >= dates[2].range.start_col then return dates[2] end
  return dates[1]
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

---@param before boolean?
function FeyMappings:table_create(before)
  local count = vim.v.count
  local w, h
  if count == 0 then
    vim.ui.input({
      prompt = 'Table size (cols, rows): ',
      scope = 'buffer',
    }, function(input)
      if not input then return end
      w, h = unpack(vim.iter(input:gmatch('%d+')):map(tonumber):totable())
      w = w or 2
      h = h or w or 2
    end)
  else
    w, h = count, count
  end

  if not w then return end
  local lines = {}
  for _ = 1, h do
    table.insert(lines, ('|   '):rep(w) .. '|')
  end

  local line = vim.fn.line('.')
  if before then line = line - 1 end
  vim.fn.append(line, lines)
end

local BOUNDARY_CHARS = {
  start = { t = 'v', m = '-' },
  inner = { t = '+', m = '~' },
  ['end'] = { t = '^', m = '-' },
  div = { t = '+', m = '=' },
}

local function make_string(tbl, t, m)
  local s = t
  for i = 1, tbl.col_count do
    s = s .. m:rep(tbl.col_widths[i] + 2) .. t
  end
  return s
end

---@param type string
---@param before boolean?
function FeyMappings:table_insert_boundary(type, before)
  local tbl = tableops.get_ctx()
  if not tbl then return end
  tbl:calculate_widths()

  local chars = BOUNDARY_CHARS[type]
  if not chars then error(('table_insert_boundary: unknown boundary type %q'):format(type), 2) end

  local newline = make_string(tbl, chars.t, chars.m)

  local line = vim.fn.line('.')
  if before then line = line - 1 end
  vim.fn.append(line, newline)
end

---@param direction string
---@param before boolean?
function FeyMappings:table_merge_cell_content(direction, before) tableops.table_cell_content_merge(direction, before) end

function FeyMappings:table_reformat() tableops.reformat() end

---@param choice string 'before' | 'after'
function FeyMappings:table_insert_row(choice)
  ({ before = tableops.insert_row_before, after = tableops.insert_row_after })[choice]()
end

---@param choice string 'up' | 'down'
function FeyMappings:table_move_row(choice) ({ up = tableops.move_row_up, down = tableops.move_row_down })[choice]() end

---@param choice string 'before' | 'after'
function FeyMappings:table_insert_col(choice)
  ({ before = tableops.insert_col_before, after = tableops.insert_col_after })[choice]()
end

---@param choice string 'left' | 'right'
function FeyMappings:table_move_col(choice) ({ left = tableops.move_col_left, right = tableops.move_col_right })[choice]() end

---@param choice string 'row' | 'col'
function FeyMappings:table_delete(choice) ({ row = tableops.delete_row, col = tableops.delete_col })[choice]() end

---@param choice string 'up' | 'down' | 'left' | 'right'
function FeyMappings:table_move_cell(choice)
  ({
    up = tableops.move_cell_up,
    down = tableops.move_cell_down,
    left = tableops.move_cell_left,
    right = tableops.move_cell_right,
  })[choice]()
end

---@param choice string 'up' | 'down' | 'left' | 'right'
function FeyMappings:table_merge_cell(choice)
  ({
    up = tableops.merge_cell_up,
    down = tableops.merge_cell_down,
    left = tableops.merge_cell_left,
    right = tableops.merge_cell_right,
    unmerge = tableops.unmerge_cells,
  })[choice]()
end

---@param choice string 'up' | 'down' | 'left' | 'right'
function FeyMappings:table_goto_cell(choice)
  ({
    up = tableops.goto_cell_up,
    down = tableops.goto_cell_down,
    left = tableops.goto_cell_left,
    right = tableops.goto_cell_right,
  })[choice]()
end

return FeyMappings
