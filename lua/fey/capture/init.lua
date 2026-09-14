local utils = require('fey.utils')
local fs = require('fey.utils.fs')
local config = require('fey.config')
local Templates = require('fey.capture.templates')
local Template = require('fey.capture.template')
local Menu = require('fey.ui.menu')
local Range = require('fey.files.elements.range')
local CaptureWindow = require('fey.capture.window')
local Date = require('fey.objects.date')
local Datetree = require('fey.capture.template.datetree')
local Input = require('fey.ui.input')
local Promise = require('fey.utils.promise')

---@alias FeyOnCaptureClose fun(capture:FeyCapture, opts:FeyProcessCaptureOpts)
---@alias FeyOnCaptureCancel fun(capture:FeyCapture)

---@class FeyCapture
---@field templates FeyCaptureTemplates
---@field closing_note FeyCaptureWindow
---@field files FeyFiles
---@field on_pre_refile FeyOnCaptureClose
---@field on_post_refile FeyOnCaptureClose
---@field on_cancel_refile FeyOnCaptureCancel
---@field private _windows table<number, FeyCaptureWindow>
local Capture = {}
Capture.__index = Capture

---@param opts { files: FeyFiles, templates?: FeyCaptureTemplates, on_pre_refile?: FeyOnCaptureClose, on_post_refile?: FeyOnCaptureClose, on_cancel_refile?: FeyOnCaptureCancel }
function Capture:new(opts)
  local this = setmetatable({}, self)
  this.files = opts.files
  this.on_pre_refile = opts.on_pre_refile
  this.on_post_refile = opts.on_post_refile
  this.on_cancel_refile = opts.on_cancel_refile
  this.templates = opts.templates or Templates:new()
  this.closing_note = this:_setup_closing_note()
  this._windows = {}
  return this
end

function Capture:prompt()
  self:_create_prompt(self.templates:get_list())
end

---@private
function Capture:setup_mappings()
  local maps = config:get_mappings('capture', vim.api.nvim_get_current_buf())
  if not maps then
    return
  end
  local capture_map = maps.fey_capture_finalize
  capture_map.map_entry
    :with_handler(function()
      return self:refile()
    end)
    :attach(capture_map.default_map, capture_map.user_map, capture_map.opts)

  local refile_map = maps.fey_capture_refile
  refile_map.map_entry
    :with_handler(function()
      return self:refile_to_destination()
    end)
    :attach(refile_map.default_map, refile_map.user_map, refile_map.opts)

  local kill_map = maps.fey_capture_kill
  kill_map.map_entry
    :with_handler(function()
      return self:kill(true)
    end)
    :attach(kill_map.default_map, kill_map.user_map, kill_map.opts)
end

---@param template FeyCaptureTemplate
---@return FeyPromise<FeyCaptureWindow>
function Capture:open_template(template)
  local window = CaptureWindow:new({
    template = template,
    on_open = function(capture_window)
      self._windows[capture_window.id] = capture_window
      return self:setup_mappings()
    end,
    on_close = function(capture_window)
      return self:on_refile_close(capture_window)
    end,
  })

  return window:open()
end

---@param shortcut string
function Capture:open_template_by_shortcut(shortcut)
  local template = self.templates:get_list()[shortcut]
  if not template then
    return utils.echo_error('No capture template with shortcut ' .. shortcut)
  end
  return self:open_template(template)
end

---@param capture_window FeyCaptureWindow
function Capture:on_refile_close(capture_window)
  local opts = self:_get_refile_vars(capture_window)
  if not opts then
    return
  end
  if capture_window:is_modified() then
    local choice =
      vim.fn.confirm(string.format('Do you want to refile this to %s?', opts.destination_file.filename), '&Yes\n&No')
    vim.cmd([[redraw!]])
    if choice ~= 1 then
      if self.on_cancel_refile then
        self.on_cancel_refile(self)
      end
      return utils.echo_info('Canceled.')
    end
  end

  vim.schedule(function()
    self:_refile_from_capture_buffer(opts)
  end)
end

---Triggered when refiling from capture buffer
function Capture:refile()
  local capture_window = self._windows[vim.b.fey_capture_window_id]
  local opts = self:_get_refile_vars(capture_window)
  if not opts then
    return
  end

  self:_refile_from_capture_buffer(opts)
end

---Refile to destination from capture buffer
function Capture:refile_to_destination()
  local source_file = self.files:get_current_file()
  local source_heading = source_file:get_headings()[1]
  local capture_window = self._windows[vim.b.fey_capture_window_id]
  return self:get_destination():next(function(destination)
    if not destination then
      return false
    end
    return self:_refile_from_capture_buffer({
      template = capture_window.template,
      capture_window = capture_window,
      source_file = source_file,
      source_heading = source_heading,
      destination_file = destination.file,
      destination_heading = destination.heading,
    })
  end)
end

---Triggered from fey file when we want to refile heading
function Capture:refile_heading_to_destination()
  return self:_refile_from_fey_file({
    source_heading = self.files:get_closest_heading(),
  })
end

---@private
---@param opts FeyProcessCaptureOpts
function Capture:_refile_from_capture_buffer(opts)
  if self.on_pre_refile then
    self.on_pre_refile(self, opts)
  end
  local target_level = 0
  local target_line = -1
  local destination_file = opts.destination_file
  local destination_heading = opts.destination_heading

  if destination_heading then
    target_line = destination_heading:get_range().end_line
  end

  if opts.template.datetree then
    destination_heading, target_line = Datetree:new({ files = self.files }):create(opts.template)
  end

  if destination_heading then
    target_level = destination_heading:get_level()
  end

  local lines = opts.source_file.lines

  if opts.source_heading then
    lines = opts.source_heading:get_lines()
    if destination_heading or opts.source_heading:get_level() > 1 then
      lines = self:_adapt_heading_level(opts.source_heading, target_level, false)
    end
  end

  lines = opts.template:apply_properties_to_lines(lines)

  destination_file:update_sync(function(file)
    if not destination_heading and opts.template.regexp then
      local line = vim.fn.search(opts.template.regexp, 'ncw')
      if line > 0 then
        return vim.api.nvim_buf_set_lines(file:bufnr(), line, line, false, lines)
      end
    end

    local range = self:_get_destination_range_without_empty_lines(Range.from_line(target_line))
    vim.api.nvim_buf_set_lines(file:bufnr(), range.start_line, range.end_line, false, lines)
  end)

  if self.on_post_refile then
    self.on_post_refile(self, opts)
  end
  utils.echo_info(('Wrote %s'):format(destination_file.filename))
  self:kill(false, opts.capture_window.id)
  return true
end

---Refile a heading from a regular fey file (non-capture)
---@private
---@param opts FeyProcessRefileOpts
---@return FeyPromise<number>
function Capture:_refile_from_fey_file(opts)
  local source_heading = opts.source_heading
  local source_file = source_heading.file
  local destination_file = opts.destination_file
  local destination_heading = opts.destination_heading

  return Promise.resolve()
    :next(function()
      if not opts.destination_file then
        return self:get_destination():next(function(destination)
          if not destination then
            return false
          end
          destination_file = destination.file
          destination_heading = destination.heading
          return destination
        end)
      end
    end)
    :next(function()
      if not destination_file then
        return false
      end

      local is_same_file = source_file.filename == destination_file.filename

      local target_level = 0
      local target_line = -1

      if destination_heading then
        target_level = destination_heading:get_level()
        target_line = destination_heading:get_range().end_line
      end

      local lines = source_heading:get_lines()

      if destination_heading or source_heading:get_level() > 1 then
        lines = self:_adapt_heading_level(source_heading, target_level, is_same_file)
      end

      destination_file:update_sync(function()
        if is_same_file then
          local item_range = source_heading:get_range()
          return vim.cmd(
            string.format('silent! %d,%d move %s', item_range.start_line, item_range.end_line, target_line)
          )
        end

        local range = self:_get_destination_range_without_empty_lines(Range.from_line(target_line))
        target_line = range.start_line
        vim.api.nvim_buf_set_lines(0, range.start_line, range.end_line, false, lines)
      end)

      if not is_same_file and source_file.filename == utils.current_file_path() then
        local item_range = source_heading:get_range()
        vim.api.nvim_buf_set_lines(0, item_range.start_line - 1, item_range.end_line, false, {})
      end

      utils.echo_info(opts.message or ('Wrote %s'):format(destination_file.filename))
      return target_line + 1
    end)
end

---@param heading FeyHeading
function Capture:refile_file_heading_to_archive(heading)
  local file = heading.file

  if file:is_archive_file() then
    return utils.echo_warning('This file is already an archive file.')
  end

  local archive_location = file:get_archive_file_location()
  if not archive_location then
    return
  end

  local archive_directory = vim.fn.fnamemodify(archive_location, ':p:h')
  if vim.fn.isdirectory(archive_directory) == 0 then
    vim.fn.mkdir(archive_directory, 'p')
  end
  if not vim.uv.fs_stat(archive_location) then
    vim.fn.writefile({}, archive_location)
  end

  local destination_file = self.files:get(archive_location)
  local todo_state = heading:get_todo()
  local heading_category = heading:get_category()
  local outline_path = heading:get_outline_path()

  return self
    :_refile_from_fey_file({
      source_heading = heading,
      destination_file = destination_file,
      message = ('Archived to %s'):format(destination_file.filename),
    })
    :next(function(target_line)
      destination_file = self.files:get(archive_location)
      return destination_file:update(function(archive_file)
        local archived_heading = archive_file:get_closest_heading({ target_line, 0 })
        archived_heading:set_property('ARCHIVE_TIME', Date.now():to_string())
        archived_heading:set_property('ARCHIVE_FILE', file.filename)
        if outline_path ~= '' then
          archived_heading:set_property('ARCHIVE_OLPATH', outline_path)
        end
        archived_heading:set_property('ARCHIVE_CATEGORY', heading_category)
        archived_heading:set_property('ARCHIVE_TODO', todo_state or '')
      end)
    end)
end

---@param item FeyHeading
---@param target_level integer
---@param is_same_file boolean
function Capture:_adapt_heading_level(item, target_level, is_same_file)
  -- Refiling in same file just moves the lines from one position
  -- to another,so we need to apply demote instantly
  local level = item:get_level()
  if target_level == 0 then
    return item:promote(level - 1, true, not is_same_file)
  end
  if level <= target_level then
    return item:demote(target_level - level + 1, true, not is_same_file)
  end
  return item:promote(level - target_level - 1, true, not is_same_file)
end

--- Modify provided range to overwrite empty lines in the destination range
--- Example destination file:
--- ------------
--- * Heading 1
---
---
--- * Heading 2
--- ------------
--- Refiling "Heading 3" to "Heading 1" will remove empty line and we get this:
--- ------------
--- * Heading 1
--- ** Heading 3
--- * Heading 2
--- ------------
function Capture:_get_destination_range_without_empty_lines(range)
  local line_count = vim.api.nvim_buf_line_count(0)

  local end_line = range.end_line
  if end_line < 0 then
    end_line = end_line + line_count + 1
  end

  local start_line = end_line - 1

  local is_line_empty = function(row)
    local line = vim.api.nvim_buf_get_lines(0, row, row + 1, true)[1]
    line = vim.trim(line)
    return #line == 0
  end

  while start_line >= 0 and is_line_empty(start_line) do
    start_line = start_line - 1
  end
  start_line = start_line + 1

  while end_line < line_count and is_line_empty(end_line) do
    end_line = end_line + 1
  end

  range.start_line = start_line
  range.end_line = end_line
  return range
end

--- Prompt for file (and heading) where to refile to
--- @return FeyPromise<{ file: FeyFile, heading?: FeyHeading}>
function Capture:get_destination()
  local valid_destinations = self:_get_autocompletion_files()

  return Input.open('Enter destination: ', '', function(arg_lead)
    return self:autocomplete_refile(arg_lead, valid_destinations)
  end):next(function(destination)
    if not destination then
      return false
    end

    local path = destination:match('^.*%.fey/?')
    local heading_title = path and destination:sub(#path + 1) or ''

    if not vim.endswith(path, '/') then
      path = path .. '/'
    end

    if not valid_destinations[path] then
      utils.echo_error(
        ('"%s" is not a is not a file specified in the "fey_agenda_files" setting. Refiling cancelled.'):format(path)
      )
      return false
    end

    local destination_file = valid_destinations[path]
    local result = {
      file = destination_file,
    }

    if not heading_title or vim.trim(heading_title) == '' then
      return result
    end

    local headings = vim.tbl_filter(function(item)
      local pattern = '^' .. vim.pesc(heading_title:lower()) .. '$'
      return item:get_title():lower():match(pattern)
    end, destination_file:get_opened_unfinished_headings())

    if not headings[1] then
      utils.echo_error(
        ("'%s' is not a valid heading in '%s'. Refiling cancelled."):format(heading_title, destination_file.filename)
      )
      return {}
    end

    return {
      file = destination_file,
      heading = headings[1],
    }
  end)
end

---@param arg_lead string
---@param files table<string, FeyFile>
---@return string[]
function Capture:autocomplete_refile(arg_lead, files)
  if not arg_lead or #arg_lead == 0 then
    return vim.tbl_keys(files)
  end

  local filename = arg_lead:match('^.*%.fey/')

  local selected_file = filename and files[filename]

  if not selected_file then
    return vim.fn.matchfuzzy(vim.tbl_keys(files), filename or arg_lead)
  end

  local headings = selected_file:get_opened_unfinished_headings()
  local result = vim.tbl_map(function(heading)
    return string.format('%s%s', filename, heading:get_title())
  end, headings)

  return vim.tbl_filter(function(item)
    return item:match(string.format('^%s', vim.pesc(arg_lead)))
  end, result)
end

function Capture:build_note_capture(title)
  return CaptureWindow:new({
    template = Template:new({
      template = '# ' .. title .. '\n\n%?',
    }),
    on_finish = function(content)
      local result = {}

      -- Remove lines from the beginning that are empty or comments
      -- until we find a non-empty line
      local trim_obsolete = true

      for _, line in ipairs(content) do
        local is_non_empty_line = not line:match('^%s*#%s') and vim.trim(line) ~= ''

        if trim_obsolete and is_non_empty_line then
          trim_obsolete = false
        end

        if not trim_obsolete then
          table.insert(result, line)
        end
      end

      if #result == 0 then
        return nil
      end

      local has_non_empty_line = vim.tbl_filter(function(line)
        return vim.trim(line) ~= ''
      end, result)

      if has_non_empty_line then
        return result
      end

      return nil
    end,
    on_open = function(capture_window)
      local maps = config:get_mappings('note', vim.api.nvim_get_current_buf())
      if not maps then
        return
      end
      local finalize_map = maps.fey_note_finalize
      finalize_map.map_entry
        :with_handler(function()
          return capture_window:finish()
        end)
        :attach(finalize_map.default_map, finalize_map.user_map, finalize_map.opts)

      local kill_map = maps.fey_note_kill
      kill_map.map_entry
        :with_handler(function()
          return capture_window:kill()
        end)
        :attach(kill_map.default_map, kill_map.user_map, kill_map.opts)
    end,
    on_close = function(capture_window)
      local is_modified = vim.bo.modified

      if is_modified then
        local choice = vim.fn.confirm('Do you want to capture this note?', '&Yes\n&No')
        vim.cmd([[redraw!]])
        if choice ~= 1 then
          return utils.echo_info('Canceled.')
        end
      end

      capture_window:finish()
    end,
  })
end

---@param from_mapping? boolean
---@param window_id? number
function Capture:kill(from_mapping, window_id)
  local window = self._windows[window_id or vim.b.fey_capture_window_id]
  if window then
    if from_mapping and self.on_cancel_refile then
      self.on_cancel_refile(self)
    end
    window:kill()
    self._windows[window.id] = nil
  end
end

---@private
---@param capture_window FeyCaptureWindow
---@return FeyProcessCaptureOpts | false
function Capture:_get_refile_vars(capture_window)
  local source_file = self.files:get(vim.api.nvim_buf_get_name(capture_window:get_bufnr()))
  local source_heading = nil
  if not capture_window.template.whole_file then
    source_heading = source_file:get_headings()[1]
  end

  local opts = {
    source_file = source_file,
    source_heading = source_heading,
    destination_file = nil,
    destination_heading = nil,
    template = capture_window.template,
    capture_window = capture_window,
  }

  if self.on_pre_refile then
    self.on_pre_refile(self, opts)
  end

  local file = opts.template:get_target()
  if vim.fn.filereadable(file) == 0 then
    local choice = vim.fn.confirm(('Refile destination %s does not exist. Create now?'):format(file), '&Yes\n&No')
    if choice ~= 1 then
      utils.echo_error('Cannot proceed without a valid refile destination')
      return false
    end
    vim.fn.mkdir(vim.fn.fnamemodify(file, ':h'), 'p')
    vim.fn.writefile({}, file)
  end

  opts.destination_file = self.files:get(file)
  if opts.template.heading then
    local template_heading = opts.template.heading
    if type(template_heading) == 'function' then
      local ok, resolved_heading = pcall(template_heading, opts.destination_file)
      if not ok then
        utils.echo_error('Failed to resolve capture template heading')
        return false
      end
      template_heading = resolved_heading
    end
    if type(template_heading) ~= 'string' then
      utils.echo_error('Capture template heading function must return a string')
      return false
    end

    opts.destination_heading = opts.destination_file:find_heading_by_title(template_heading)
    if not opts.destination_heading then
      utils.echo_error(('Refile heading "%s" does not exist in "%s"'):format(template_heading, file))
      return false
    end
  end

  return opts
end

---@deprecated
---@private
function Capture:_setup_closing_note()
  return self:build_note_capture('Insert note for closed todo item')
end

---@private
---@param base_key string
---@param templates table<string, FeyCaptureTemplate>
function Capture:_get_subtemplates(base_key, templates)
  local subtemplates = {}
  for key, template in utils.sorted_pairs(templates) do
    if string.len(key) > 1 and string.sub(key, 1, 1) == base_key then
      subtemplates[string.sub(key, 2, string.len(key))] = template
    end
  end
  return subtemplates
end

---@private
---@param templates table<string, FeyCaptureTemplate>
function Capture:_create_menu_items(templates)
  local menu_items = {}
  for key, template in utils.sorted_pairs(templates) do
    if string.len(key) == 1 then
      local item = {
        key = key,
      }
      if type(template) == 'string' then
        item.label = template .. '...'
        item.action = function()
          self:_create_prompt(self:_get_subtemplates(key, templates))
        end
      elseif vim.tbl_count(template.subtemplates) > 0 then
        item.label = template.description .. '...'
        item.action = function()
          self:_create_prompt(template.subtemplates)
        end
      else
        item.label = template.description
        item.action = function()
          return self:open_template(template)
        end
      end
      table.insert(menu_items, item)
    end
  end
  return menu_items
end

---@private
---@return table<string, FeyFile>
function Capture:_get_autocompletion_files()
  local valid_destinations = {}
  local filenames = {}
  for _, file in ipairs(self.files:all()) do
    if not file:is_archive_file() then
      table.insert(valid_destinations, file)
      table.insert(filenames, file.filename)
    end
  end

  filenames = fs.trim_common_root(filenames)
  local result = {}

  for i, filename in ipairs(filenames) do
    result[filename .. '/'] = valid_destinations[i]
  end

  return result
end

---@private
---@param templates table<string, FeyCaptureTemplate>
function Capture:_create_prompt(templates)
  local menu = Menu:new({
    title = 'Select a capture template',
    items = self:_create_menu_items(templates),
    prompt = 'Template key',
  })
  menu:add_separator()
  menu:add_option({ label = 'Quit', key = 'q' })
  menu:add_separator({ icon = ' ', length = 1 })
  return menu:open()
end

return Capture
