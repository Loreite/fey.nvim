-- Capture: write a new piece of text into the notes. A template is expanded (see `fey.capture.template`),
-- the text is edited in a small window, and `<C-c>` writes it where the template says: a file, a heading of
-- it, the tree of a date, after a line that matches. The writing is `fey.refile.insert`: the text becomes a
-- child of the destination heading (or a top level heading) at the right level, signatures are renumbered,
-- and the file is saved and indexed again.
local utils = require('fey.utils')
local config = require('fey.config')
local Templates = require('fey.capture.templates')
local Template = require('fey.capture.template')
local Menu = require('fey.ui.menu')
local CaptureWindow = require('fey.capture.window')
local Datetree = require('fey.capture.template.datetree')
local Refile = require('fey.refile')
local Promise = require('fey.utils.promise')

---@alias FeyOnCaptureClose fun(capture:FeyCapture, opts:table)
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
      return self:_on_window_closed(capture_window)
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

---The window was closed by hand (`:q`): a text that was changed is offered for writing, an untouched
---template is dropped
---@private
---@param capture_window FeyCaptureWindow
function Capture:_on_window_closed(capture_window)
  if capture_window.done or not self._windows[capture_window.id] then return end
  local bufnr = capture_window:get_bufnr()
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or capture_window:is_untouched() then
    self._windows[capture_window.id] = nil
    return
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local choice = vim.fn.confirm('Do you want to write this capture?', '&Yes\n&No')
  vim.cmd([[redraw!]])
  if choice ~= 1 then
    self._windows[capture_window.id] = nil
    if self.on_cancel_refile then self.on_cancel_refile(self) end
    return utils.echo_info('Canceled.')
  end
  vim.schedule(function()
    self:_write(capture_window, nil, lines)
  end)
end

---Write the capture to the destination of its template (the mapping `fey_capture_finalize`)
function Capture:refile()
  local window = self._windows[vim.b.fey_capture_window_id]
  if not window then return end
  return self:_write(window, nil)
end

---Write the capture to a place picked from the hollows (the mapping `fey_capture_refile`)
function Capture:refile_to_destination()
  local window = self._windows[vim.b.fey_capture_window_id]
  if not window then return end
  return Refile.pick({ prompt = 'Capture to' }):next(function(destination)
    if not destination then return false end
    return self:_write(window, destination)
  end)
end

---The title of the first heading of a text, nil when it has none
---@param lines string[]
---@return string|nil
local function first_title(lines)
  local ok, meta = pcall(require('fey.vault.extract').extract, table.concat(lines, '\n') .. '\n')
  return ok and meta.headings[1] and meta.headings[1].title or nil
end

---Make sure the file of the target exists
---@private
---@param path string
---@return boolean
function Capture:_ensure_file(path)
  if vim.fn.filereadable(path) == 1 then return true end
  local choice = vim.fn.confirm(('Capture destination %s does not exist. Create now?'):format(path), '&Yes\n&No')
  if choice ~= 1 then
    utils.echo_error('Cannot proceed without a valid capture destination')
    return false
  end
  vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
  vim.fn.writefile({}, path)
  return true
end

---Find the destination heading of a template in the buffer of the file: by title or by signature
---@param template FeyCaptureTemplate
---@param path string
---@return fun(): table resolve
local function heading_resolver(template, path)
  return function()
    local wanted = template.heading
    if type(wanted) == 'function' then wanted = wanted(path) end
    if type(wanted) ~= 'string' then error('Capture template heading function must return a string', 0) end
    local files = require('fey').instance().files
    for _, heading in ipairs(files:get_current_file():get_headings()) do
      local sig = vim.trim(vim.treesitter.get_node_text(heading:get_child_node('signature'), 0))
      if heading:get_title():lower() == wanted:lower() or sig == vim.trim(wanted) then
        local first, last = Refile.subtree(heading)
        return { line = first, end_line = last, level = heading:get_level() }
      end
    end
    error(('Capture heading "%s" does not exist in "%s"'):format(wanted, path), 0)
  end
end

---The destination a template describes, with the file made sure of
---@private
---@param template FeyCaptureTemplate
---@return FeyRefileDestination|nil dest
---@return table|nil opts  options for `Refile.insert`
function Capture:_destination(template)
  local path, err = template:get_target()
  if not path then
    utils.echo_error(err or 'No capture target')
    return nil
  end
  if not self:_ensure_file(path) then return nil end
  path = vim.uv.fs_realpath(path) or path
  local dest = { abs = path }
  local opts = { adapt = true, pad = template.properties.empty_lines }
  if template.datetree then
    local dt = template:get_datetree_opts()
    dest.resolve = function() return Datetree.ensure(dt) end
    opts.reversed = dt.reversed
  elseif template.heading then
    dest.resolve = heading_resolver(template, path)
  elseif template.query then
    local found = Capture.query_destination(template.query)
    if not found then
      utils.echo_error('The capture query found no heading: ' .. template.query)
      return nil
    end
    dest = found
  elseif template.regexp then
    opts.regexp = template.regexp
  end
  return dest, opts
end

---The heading a query selects: the first cell of the first row must be a section link (`FROM @section`)
---@param src string
---@return FeyRefileDestination|nil
function Capture.query_destination(src)
  local api = require('fey.api')
  -- the query runs in the hollow of the working directory, over the scope
  local own = api.vault(vim.fn.getcwd())
  local ok, result = pcall(function()
    if not own then error('No hollow here (run :FeyHollowInit)', 0) end
    return own:run_query(src, { scope = config.fey_refile_scope or 'court' })
  end)
  local link = ok and result.rows and result.rows[1] and result.rows[1][1]
  if type(link) ~= 'table' or not link.path then return nil end

  -- a link names the hollow it is in when it is not the hollow of the vault the query ran in
  local tree = require('fey.hollow.tree')
  local root = own and own.root
  if link.hollow then
    root = tree.resolve_ref(link.hollow, root)
  end
  if not root then return nil end
  local abs = vim.fs.joinpath(root, link.path)
  local signature = link.subpath
  local dest = { abs = abs }
  if signature and signature ~= '' then
    dest.resolve = function()
      local files = require('fey').instance().files
      for _, heading in ipairs(files:get_current_file():get_headings()) do
        local sig = vim.trim(vim.treesitter.get_node_text(heading:get_child_node('signature'), 0))
        if sig == vim.trim(signature) then
          local first, last = Refile.subtree(heading)
          return { line = first, end_line = last, level = heading:get_level() }
        end
      end
      error(('no heading %s in %s'):format(signature, abs), 0)
    end
  end
  return dest
end

---Write the text of a capture window
---@private
---@param window FeyCaptureWindow
---@param destination? FeyRefileDestination where, else what the template says
---@param lines? string[] the text, else the buffer of the window
---@return FeyPromise<boolean>
function Capture:_write(window, destination, lines)
  local template = window.template
  lines = lines or vim.api.nvim_buf_get_lines(window:get_bufnr(), 0, -1, false)
  local opts = { adapt = true, pad = template.properties.empty_lines }
  if not destination then
    destination, opts = self:_destination(template)
    if not destination then return Promise.resolve(false) end
  end

  if template.unique then
    local title = first_title(lines)
    if title and Capture.title_exists(title) then
      utils.echo_error(('There is already a heading "%s"'):format(title))
      return Promise.resolve(false)
    end
  end

  local info = { template = template, capture_window = window, destination = destination, lines = lines }
  if self.on_pre_refile then self.on_pre_refile(self, info) end
  return Refile.insert(destination, lines, opts):next(function(result)
    info.result = result
    window.done = true
    self._windows[window.id] = nil
    if vim.api.nvim_buf_is_valid(window:get_bufnr() or -1) then window:kill() end
    if self.on_post_refile then self.on_post_refile(self, info) end
    utils.echo_info(('Wrote %s'):format(vim.fn.fnamemodify(destination.abs, ':t')))
    return true
  end, function(err)
    utils.echo_error(tostring(type(err) == 'table' and err.message or err))
    return false
  end)
end

---Is there a heading with this title in the hollows of `fey_refile_scope`
---@param title string
---@return boolean
function Capture.title_exists(title)
  local scope = require('fey.hollow.scope')
  local spec = config.fey_refile_scope or 'court'
  if spec == 'court' and not require('fey.hollow.court').root() then spec = 'current' end
  local root = require('fey.hollow.tree').hollow_root_of(vim.fn.getcwd())
  local rows = scope.collect(spec, root, function(vault)
    return vault:query('SELECT 1 FROM headings WHERE title = :t COLLATE NOCASE LIMIT 1', { t = title })
  end)
  return #rows > 0
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
    window.done = true
    self._windows[window.id] = nil
    window:kill()
  end
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
