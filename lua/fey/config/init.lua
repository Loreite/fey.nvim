local instance = {}
local utils = require('fey.utils')
local fs = require('fey.utils.fs')
local defaults = require('fey.config.defaults')
---@type table<string, FeyMapEntry>
local mappings = require('fey.config.mappings')
local TodoKeywords = require('fey.objects.todo_keywords')
local PriorityState = require('fey.objects.priority_state')
local constants = require('fey.utils.constants')

---@class FeyConfig:FeyConfigOpts
---@field opts table
---@field todo_keywords FeyTodoKeywords
---@field priorities table<string, { type: string, hl_group: string }>
local Config = {}

---@param opts? table
function Config:new(opts)
  local data = {
    opts = vim.tbl_deep_extend('force', defaults, opts or {}),
    todo_keywords = nil,
    priorities = nil,
  }
  setmetatable(data, self)
  return data
end

function Config:__index(key)
  if self.opts[key] ~= nil then
    return self.opts[key]
  end
  return rawget(getmetatable(self), key)
end

function Config:install_grammar()
  return require('fey.utils.treesitter.install').install()
end

function Config:reinstall_grammar()
  return require('fey.utils.treesitter.install').reinstall()
end

---@param opts table
---@return FeyConfig
function Config:extend(opts)
  self.todo_keywords = nil
  self.priorities = nil
  opts = opts or {}
  if not self:_are_priorities_valid(opts) then
    opts.fey_priority_highest = self.opts.fey_priority_highest
    opts.fey_priority_lowest = self.opts.fey_priority_lowest
    opts.fey_priority_default = self.opts.fey_priority_default
  end
  self.opts = vim.tbl_deep_extend('force', self.opts, opts)
  if self.fey_startup_indented then
    self.fey_adapt_indentation = not self.fey_indent_mode_turns_off_fey_adapt_indentation
  end
  return self
end

function Config:_are_priorities_valid(opts)
  local high = opts.fey_priority_highest
  local low = opts.fey_priority_lowest
  local default = opts.fey_priority_default

  if high or low or default then
    -- assert that all three options are set
    if not (high and low and default) then
      utils.echo_warning(
        'fey_priority_highest, fey_priority_lowest and fey_priority_default can only be set together.'
          .. 'Falling back to default priorities'
      )
      return false
    end

    -- numbers
    if type(high) == 'number' and type(low) == 'number' and type(default) == 'number' then
      if high < 0 or low < 0 or default < 0 then
        utils.echo_warning(
          'fey_priority_highest, fey_priority_lowest and fey_priority_default cannot be negative.'
            .. 'Falling back to default priorities'
        )
        return false
      end
      if high > low then
        utils.echo_warning('fey_priority_highest cannot be bigger than fey_priority_lowest. Falling back to default priorities')
        return false
      end
      if default < high or default > low then
        utils.echo_warning(
          'fey_priority_default must be bigger than fey_priority_highest and smaller than fey_priority_lowest.'
            .. 'Falling back to default priorities'
        )
        return false
      end
    -- one-char strings
    elseif
      (type(high) == 'string' and #high == 1)
      and (type(low) == 'string' and #low == 1)
      and (type(default) == 'string' and #default == 1)
    then
      if not high:match('%a') or not low:match('%a') or not default:match('%a') then
        utils.echo_warning(
          'fey_priority_highest, fey_priority_lowest and fey_priority_default must be letters.'
            .. 'Falling back to default priorities'
        )
        return false
      end

      high = string.byte(high)
      low = string.byte(low)
      default = string.byte(default)
      if high > low then
        utils.echo_warning('fey_priority_highest cannot be bigger than fey_priority_lowest. Falling back to default priorities')
        return false
      end
      if default < high or default > low then
        utils.echo_warning(
          'fey_priority_default must be bigger than fey_priority_highest and smaller than fey_priority_lowest.'
            .. 'Falling back to default priorities'
        )
        return false
      end
    else
      utils.echo_warning(
        'fey_priority_highest, fey_priority_lowest and fey_priority_default must be either of type'
          .. "'number' or of type 'string' of length one. All three options need to agree on this type."
          .. 'Falling back to default priorities'
      )
      return false
    end
  end

  return true
end

---@return number
function Config:get_week_start_day_number()
  return utils.convert_from_isoweekday(1)
end

---@return number
function Config:get_week_end_day_number()
  return utils.convert_from_isoweekday(7)
end

---@return string|number
function Config:get_agenda_span()
  local span = self.opts.fey_agenda_span
  local valid_spans = { 'day', 'month', 'week', 'year' }
  if type(span) == 'string' and not vim.tbl_contains(valid_spans, span) then
    utils.echo_warning(
      string.format('Invalid agenda span %s. Valid spans: %s. Falling back to week', span, table.concat(valid_spans, ', '))
    )
    span = 'week'
  end
  if type(span) == 'number' and span < 0 then
    utils.echo_warning(
      string.format(
        'Invalid agenda span number %d. Must be 0 or more. Falling back to week',
        span,
        table.concat(valid_spans, ', ')
      )
    )
    span = 'week'
  end
  return span
end

---@return FeyTodoKeywords
function Config:get_todo_keywords()
  if not self.todo_keywords then
    self.todo_keywords = self:build_todo_keywords()
  end
  return self.todo_keywords
end

---@param todo_keywords? string[] | string[][]
function Config:build_todo_keywords(todo_keywords)
  return TodoKeywords:new({
    fey_todo_keywords = todo_keywords or self.opts.fey_todo_keywords,
    fey_todo_keyword_faces = self.opts.fey_todo_keyword_faces,
  })
end

--- Setup mappings for a given category and buffer
---@param category string Mapping category name (e.g. `agenda`, `capture`, `fey`)
---@param buffer number? Buffer id
---@see fey.config.mappings
function Config:setup_mappings(category, buffer)
  local maps = self:get_mappings(category, buffer)
  if not maps then
    return
  end

  for _, map in pairs(maps) do
    map.map_entry:attach(map.default_map, map.user_map, map.opts)
  end
end

function Config:get_mappings(category, buffer)
  if self.opts.mappings.disable_all then
    return
  end

  local map_entries = mappings[category]
  local default_mappings = defaults.mappings[category] or {}
  local user_mappings = vim.tbl_get(self.opts.mappings, category) or {}
  local opts = {}
  if buffer then
    opts.buffer = buffer
  end

  if self.opts.mappings.prefix then
    opts.prefix = self.opts.mappings.prefix
  end

  local result = {}
  for name, map_entry in pairs(map_entries) do
    result[name] = {
      map_entry = map_entry,
      default_map = default_mappings[name],
      user_map = user_mappings[name],
      opts = opts,
    }
  end
  return result
end

--- Setup the foldlevel for a given fey file
function Config:setup_foldlevel()
  if self.fey_startup_folded == 'overview' then
    vim.opt_local.foldlevel = 0
  elseif self.fey_startup_folded == 'content' then
    vim.opt_local.foldlevel = 1
  elseif self.fey_startup_folded == 'showeverything' then
    vim.opt_local.foldlevel = 99
  elseif self.fey_startup_folded ~= 'inherit' then
    utils.echo_warning("Invalid option passed for 'fey_startup_folded'!")
    self.opts.fey_startup_folded = 'overview'
    self:setup_foldlevel()
  end
end

---@return string|nil
function Config:parse_archive_location(file, archive_loc)
  if self:is_archive_file(file) then
    return nil
  end

  archive_loc = archive_loc or self.opts.fey_archive_location
  -- TODO: Support archive to heading
  local parts = vim.split(archive_loc, '::')
  local archive_location = vim.trim(parts[1])
  if not archive_location:find('%%s') then
    return vim.fn.fnamemodify(archive_location, ':p')
  end

  local file_path = vim.fn.fnamemodify(file, ':p:h')
  local file_name = vim.fn.fnamemodify(file, ':t')
  local archive_filename = string.format(archive_location, file_name)

  -- If fey_archive_location is defined as relative path (example: "archive/%s_archive")
  -- then we need to prepend the file path to it
  local is_full_path = fs.substitute_path(archive_filename)

  if not is_full_path then
    return string.format('%s/%s', file_path, archive_filename)
  end

  return vim.fn.fnamemodify(archive_filename, ':p')
end

function Config:is_archive_file(file)
  return vim.fn.fnamemodify(file, ':e') == 'fey_archive'
end

function Config:exclude_tags(tags)
  if vim.tbl_isempty(self.opts.fey_tags_exclude_from_inheritance) then
    return tags
  end

  return vim.tbl_filter(function(tag)
    return not vim.tbl_contains(self.opts.fey_tags_exclude_from_inheritance, tag)
  end, tags)
end

function Config:get_inheritable_tags(heading)
  if not heading.tags or not self.opts.fey_use_tag_inheritance then
    return {}
  end
  if vim.tbl_isempty(self.opts.fey_tags_exclude_from_inheritance) then
    return { unpack(heading.tags) }
  end

  return vim.tbl_filter(function(tag)
    return not vim.tbl_contains(self.opts.fey_tags_exclude_from_inheritance, tag)
  end, heading.tags)
end

function Config:get_priority_range()
  return {
    highest = self.fey_priority_highest,
    default = self.fey_priority_default,
    lowest = self.fey_priority_lowest,
  }
end

function Config:get_priorities()
  if self.priorities then
    return self.priorities
  end

  local priorities = {
    [self.opts.fey_priority_highest] = { type = 'highest', hl_group = '@fey.priority.highest' },
  }

  local current_prio =
    PriorityState:new(self.opts.fey_priority_highest, self:get_priority_range(), self.fey_priority_start_cycle_with_default)
  while current_prio:as_num() < current_prio:default_as_num() do
    current_prio:decrease()
    priorities[current_prio.priority] = { type = 'high', hl_group = '@fey.priority.high' }
  end

  -- we need to overwrite the default value set by the first loop
  priorities[self.opts.fey_priority_default] = { type = 'default', hl_group = '@fey.priority.default' }

  while current_prio:as_num() < current_prio:lowest_as_num() do
    current_prio:decrease()
    priorities[current_prio.priority] = { type = 'low', hl_group = '@fey.priority.low' }
  end

  -- we need to overwrite the lowest value set by the second loop
  priorities[self.opts.fey_priority_lowest] = { type = 'lowest', hl_group = '@fey.priority.lowest' }

  -- Cache priorities to avoid unnecessary recalculations
  self.priorities = priorities

  return priorities
end

function Config:setup_ts_predicates()
  local todo_keywords = self:get_todo_keywords():keys()
  local valid_priorities = self:get_priorities()

  vim.treesitter.query.add_predicate('fey-is-heading-level?', function(match, _, source, predicate)
    if type(source) == 'number' and not vim.api.nvim_buf_is_loaded(source) then
      return false
    end
    local node = match[predicate[2]]
    node = node and node[#node]
    if not node then
      return false
    end

    local target_level = tonumber(predicate[3])
    local text = vim.treesitter.get_node_text(node, source)
    local _, count = text:gsub(constants.heading_delimiters, '')

    return ((count - 1) % 8) + 1 == target_level
  end, { force = true, all = true })

  vim.treesitter.query.add_predicate('fey-is-todo-keyword?', function(match, _, source, predicate)
    local node = match[predicate[2]]
    node = node and node[#node]
    if node then
      local text = vim.treesitter.get_node_text(node, source)
      return todo_keywords[text] and todo_keywords[text].type == predicate[3] or false
    end

    return false
  end, { force = true, all = true })

  local fey_cycle_separator_lines = math.max(self.opts.fey_cycle_separator_lines, 0)

  vim.treesitter.query.add_directive('fey-set-fold-offset!', function(match, _, bufnr, pred, metadata)
    if fey_cycle_separator_lines == 0 then
      return
    end
    local capture_id = pred[2]
    local section_node = match[capture_id]
    section_node = section_node and section_node[#section_node]
    if not capture_id or not section_node or section_node:type() ~= 'section' then
      return
    end
    if not metadata[capture_id] then
      metadata[capture_id] = {}
    end
    local range = metadata[capture_id].range or { section_node:range() }
    local start_row = range[1]
    local end_row = range[3]

    local empty_lines = 0
    while end_row > start_row do
      local line = vim.api.nvim_buf_get_lines(bufnr, end_row - 1, end_row, false)[1]
      if vim.trim(line) ~= '' then
        break
      end
      empty_lines = empty_lines + 1
      end_row = end_row - 1
    end

    if empty_lines < fey_cycle_separator_lines then
      return
    end
    range[3] = range[3] - 1
    metadata[capture_id].range = range
  end, { force = true, all = true })

  vim.treesitter.query.add_predicate('fey-is-valid-priority?', function(match, _, source, predicate)
    ---@type TSNode | nil
    local node = match[predicate[2]]
    node = node and node[#node]
    if not node then
      return false
    end

    local type = predicate[3]
    local text = vim.treesitter.get_node_text(node, source)
    -- Leave only priority cookie: [#A] -> A
    text = text:sub(3, -2)
    return valid_priorities[text] and valid_priorities[text].type == type
  end, { force = true, all = true })

  vim.treesitter.query.add_directive('fey-set-block-language!', function(match, _, bufnr, pred, metadata)
    local lang_node = match[pred[2]]
    lang_node = lang_node and lang_node[#lang_node]
    if not lang_node then
      return
    end
    local text = vim.treesitter.get_node_text(lang_node, bufnr)
    if not text or vim.trim(text) == '' then
      return
    end
    metadata['injection.language'] = self:detect_filetype(text)
  end, { force = true, all = true })

  vim.treesitter.query.add_directive('fey-set-inline-block-language!', function(match, _, bufnr, pred, metadata)
    local lang_node = match[pred[2]]
    lang_node = lang_node and lang_node[#lang_node]
    if not lang_node then
      return
    end
    local text = vim.treesitter.get_node_text(lang_node, bufnr)
    if not text or vim.trim(text) == '' then
      return
    end
    -- Remove `src_` part: src_lua -> lua
    text = text:sub(5)
    -- Remove opening brackend and parameters: lua[params]{ -> lua
    text = text:gsub('[%{%[].*', '')
    metadata['injection.language'] = self:detect_filetype(text)
  end, { force = true, all = true })

  vim.treesitter.query.add_predicate('fey-hide-leading-signature?', function(_, _, source)
    return self:hide_leading_signature(source --[[@as number]])
  end, { force = true })
end

---@param content table
---@param option? string
---@param prepend_content? any
---@return table
function Config:respect_blank_before_new_entry(content, option, prepend_content)
  if self.opts.fey_blank_before_new_entry[option or 'heading'] then
    table.insert(content, 1, prepend_content or '')
  end
  return content
end

---Check if buffer should apply indentation
---@param bufnr number
---@return boolean
function Config:should_indent(bufnr)
  if bufnr > -1 and vim.b[bufnr].fey_indent_mode then
    return not self.opts.fey_indent_mode_turns_off_fey_adapt_indentation
  end

  return self.fey_adapt_indentation
end

---@param amount number
---@param bufnr number
---@return string
function Config:get_indent(amount, bufnr)
  if self:should_indent(bufnr) then
    return string.rep(' ', amount)
  end

  return ''
end

---@param bufnr number
---@return boolean
function Config:hide_leading_signature(bufnr)
  if self.fey_hide_leading_signature then
    return true
  end

  if vim.b[bufnr].fey_indent_mode and self.fey_indent_mode_turns_on_hiding_signature then
    return true
  end

  return false
end

---@param args string
---@return table<string, string[]>
function Config:parse_header_args(args)
  local results = {}
  local current_argument = nil
  local list = vim.split(args, '%s+')
  for _, param in ipairs(list) do
    local is_header_argument = param:sub(1, 1) == ':'
    if is_header_argument then
      results[param:lower()] = {}
      current_argument = param:lower()
    elseif current_argument then
      table.insert(results[current_argument], param)
    end
  end

  for name, value in pairs(results) do
    results[name] = table.concat(value, ' ')
  end

  return results
end

---@param property_name string
---@return boolean uses_inheritance
function Config:use_property_inheritance(property_name)
  property_name = string.lower(property_name)

  local use_inheritance = self.opts.fey_use_property_inheritance or false

  if type(use_inheritance) == 'table' then
    return vim.tbl_contains(use_inheritance, function(value)
      return vim.stricmp(value, property_name) == 0
    end, { predicate = true })
  elseif type(use_inheritance) == 'string' then
    local regex = vim.regex(use_inheritance)
    return regex:match_str(property_name) and true or false
  else
    return use_inheritance and true or false
  end
end

-- Return repeat count depending on `fey_agenda_show_future_repeats` value.
-- If nil, repeat infinitely.
-- @return number|nil
function Config:get_repeat_count()
  if self.fey_agenda_show_future_repeats == true then
    return nil
  end

  if self.fey_agenda_show_future_repeats == false then
    return 0
  end

  if self.fey_agenda_show_future_repeats == 'next' then
    return 1
  end
  if type(self.fey_agenda_show_future_repeats) == 'number' and self.fey_agenda_show_future_repeats >= 0 then
    return self.fey_agenda_show_future_repeats
  end

  utils.echo_error({
    'Invalid value for `fey_agenda_show_future_repeats`',
    'Either boolean, positive number or "next" expected',
    'Defaulting to "true"',
  })

  return nil
end

---@param filetype_name string
---@param use_ftmatch? boolean Use vim.filetype.match to detect filetype
function Config:detect_filetype(filetype_name, use_ftmatch)
  local name = filetype_name:lower()

  if not self._ft_map then
    self._ft_map = {}
  end

  if self._ft_map[name] then
    return self._ft_map[name]
  end

  local filetype = self:_get_filetype_name(name)

  if use_ftmatch then
    local filename = '__fey__detect_filetype__.' .. filetype
    local ft = vim.filetype.match({ filename = filename })
    if ft then
      self._ft_map[name] = ft
      return ft
    end
  end

  self._ft_map[name] = filetype
  return filetype
end

---@private
---@param filetype string
function Config:_get_filetype_name(filetype)
  local map = {
    ['emacs-lisp'] = 'lisp',
    elisp = 'lisp',
    js = 'javascript',
    ts = 'typescript',
    md = 'markdown',
    ex = 'elixir',
    pl = 'perl',
    sh = 'bash',
    shell = 'bash',
    uxn = 'uxntal',
  }
  if map[filetype] then
    return map[filetype]
  end

  if self.opts.fey_edit_src_filetype_map[filetype] then
    return self.opts.fey_edit_src_filetype_map[filetype]
  end

  return filetype
end

---@type FeyConfig
instance = Config:new()
return instance
