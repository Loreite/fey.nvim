local TemplateProperties = require('fey.capture.template.template_properties')
local Date = require('fey.objects.date')
local utils = require('fey.utils')
local Calendar = require('fey.objects.calendar')
local Promise = require('fey.utils.promise')
local Input = require('fey.ui.input')

---Ask for a date, as text for a tag: `2026-10-06 Tue`, with the time when asked
---@param with_time boolean
---@param title? string
---@param as_tag? boolean write the whole inactive date tag instead of the value
---@return FeyPromise<string|nil>
local function ask_date(with_time, title, as_tag)
  local start = with_time and Date.now() or Date.today()
  return Calendar.new({ date = start, title = title }):open():next(function(date)
    if not date then return nil end
    if as_tag then return date:to_tag_text({ active = false }) end
    return date:to_tag_value()
  end)
end

-- What `%x` stands for in a template. Dates are written the way the date tags want them: `%t` is
-- `2026-10-06 Tue` (for a planning tag: `{# scheduled, %t #}`), `%T` adds the time, and `%u` / `%U` are whole
-- inactive date tags, `{@ date, 2026-10-06 Tue; active: false @}`, for "created on". `%^t` and the others
-- with a caret ask with the calendar. `%a` is a link to where the capture started.
local expansions = {
  ['%%f'] = function() return vim.fn.expand('%') end,
  ['%%F'] = function() return vim.fn.expand('%:p') end,
  ['%%n'] = function()
    if vim.fn.has('win32') == 1 then return os.getenv('USERNAME') end
    return os.getenv('USER')
  end,
  ['%%x'] = function() return vim.fn.getreg('+') end,
  ['%%t'] = function() return Date.today():to_tag_value() end,
  ['%%%^t'] = function() return ask_date(false) end,
  ['%%%^%{([^%}]*)%}t'] = function(title) return ask_date(false, title) end,
  ['%%T'] = function() return Date.now():to_tag_value() end,
  ['%%%^T'] = function() return ask_date(true) end,
  ['%%%^%{([^%}]*)%}T'] = function(title) return ask_date(true, title) end,
  ['%%u'] = function() return Date.today():to_tag_text({ active = false }) end,
  ['%%%^u'] = function() return ask_date(false, nil, true) end,
  ['%%%^%{([^%}]*)%}u'] = function(title) return ask_date(false, title, true) end,
  ['%%U'] = function() return Date.now():to_tag_text({ active = false }) end,
  ['%%%^U'] = function() return ask_date(true, nil, true) end,
  ['%%%^%{([^%}]*)%}U'] = function(title) return ask_date(true, title, true) end,
  ['%%a'] = function() return require('fey.capture.template').link_here() end,
}

---@class FeyCaptureTemplateOpts
---@field description? string
---@field template? string|string[]
---@field target? string
---@field datetree? FeyCaptureTemplateDatetree
---@field heading? string|fun(path: string):string  the title or the signature (`I.A.`) of the heading the text goes under
---@field query? string  a query that selects the heading: its first row must be a section (`TABLE ... FROM @section WHERE ...`)
---@field unique? boolean  refuse a title that is already a heading title of the hollows of `fey_refile_scope`
---@field regexp? string
---@field properties? FeyCaptureTemplateProperties
---@field subtemplates? table<string, FeyCaptureTemplate>
---@field whole_file? boolean  accepted, the whole text is always written

---@class FeyCaptureTemplate:FeyCaptureTemplateOpts
---@field private _compile_hooks (fun(content:string, content_type: 'target' | 'content'):string | nil)[]
local Template = {}

---A link tag to the place the capture started: the heading under the cursor of a document, else the file
---@return string
function Template.link_here()
  local name = vim.api.nvim_buf_get_name(0)
  if name == '' or not utils.is_fey_file(name) then return '' end
  local abs = vim.uv.fs_realpath(name) or name
  local tree = require('fey.hollow.tree')
  local root = tree.hollow_root_of(abs)
  local id = root and tree.id_of(root)
  local rel = root and vim.fs.relpath(root, abs) or abs
  local target = id and (id .. '/' .. rel) or rel
  local desc, section
  local ok, heading = pcall(function() return require('fey').instance().files:get_closest_heading() end)
  if ok and heading then
    desc = heading:get_title()
    section = vim.trim(vim.treesitter.get_node_text(heading:get_child_node('signature'), 0))
  end
  return require('fey.api').link_text(target, { desc = desc, section = section })
end

---@param opts FeyCaptureTemplateOpts
---@return FeyCaptureTemplate
function Template:new(opts)
  opts = opts or {}

  vim.validate('description', opts.description, 'string', true)
  vim.validate('template', opts.template, { 'string', 'table' }, true)
  vim.validate('target', opts.target, 'string', true)
  vim.validate('regexp', opts.regexp, 'string', true)
  vim.validate('heading', opts.heading, { 'string', 'function' }, true)
  vim.validate('properties', opts.properties, 'table', true)
  vim.validate('subtemplates', opts.subtemplates, 'table', true)
  vim.validate('datetree', opts.datetree, { 'boolean', 'table' }, true)
  vim.validate('whole_file', opts.whole_file, 'boolean', true)
  vim.validate('query', opts.query, 'string', true)
  vim.validate('unique', opts.unique, 'boolean', true)

  local this = {}
  this.description = opts.description or ''
  this.template = opts.template or ''
  this.target = opts.target or ''
  this.heading = opts.heading
  this.properties = TemplateProperties:new(opts.properties)
  this.datetree = opts.datetree
  this.regexp = opts.regexp
  this.whole_file = opts.whole_file
  this.query = opts.query
  this.unique = opts.unique

  this.subtemplates = {}
  for key, subtemplate in pairs(opts.subtemplates or {}) do
    this.subtemplates[key] = Template:new(subtemplate)
  end

  setmetatable(this, self)
  self.__index = self
  return this
end

function Template:setup()
  local initial_position = vim.fn.search('%?')
  local is_at_end_of_line = vim.fn.search('%?$') > 0
  if initial_position > 0 then
    vim.cmd([[norm!"_c2l]])
    if is_at_end_of_line then
      vim.cmd([[startinsert!]])
    else
      vim.cmd([[norm!l]])
      vim.cmd([[startinsert]])
    end
  end
end

function Template:on_compile(hook)
  self._compile_hooks = self._compile_hooks or {}
  table.insert(self._compile_hooks, hook)
  return self
end

function Template:validate_options()
  self:_validate_regexp()
  if self.datetree then
    if type(self.datetree) == 'table' then
      if self.datetree.tree_type == 'custom' and not self.datetree.tree then
        utils.echo_error('Custom datetree type requires a tree option')
      end
    end
  end
end

function Template:_validate_regexp()
  local places = 0
  for _, v in ipairs({ self.heading, self.regexp, self.query, self.datetree }) do
    if v then places = places + 1 end
  end
  if places > 1 then
    local desc = self.description ~= '' and self.description or self.template
    utils.echo_error(
      ('A capture template can have one of heading, regexp, query and datetree: "%s"'):format(desc)
    )
  end
end

function Template:_validate_datetree()
  if not self.datetree or self.datetree == true then
    return
  end
  if type(self.datetree) ~= 'table' then
    return utils.echo_error('Datetree option must be a table or a boolean')
  end
  if self.datetree.tree_type then
    local valid_tree_types = { 'day', 'week', 'month', 'custom' }
    if not vim.tbl_contains(valid_tree_types, self.datetree.tree_type) then
      return utils.echo_error(('Invalid tree type "%s"'):format(self.datetree.tree_type))
    end

    if self.datetree.tree_type == 'custom' then
      if not self.datetree.tree or type(self.datetree.tree) ~= 'table' then
        return utils.echo_error('Custom tree type requires a tree option to be a table (array of FeyDatetreeTreeItem)')
      end
      if #self.datetree.tree == 0 then
        return utils.echo_error(
          'Custom tree type requires a tree option to be a non-empty table (array of FeyDatetreeTreeItem)'
        )
      end
    end
  end
end

function Template:compile()
  self:validate_options()
  local content = self.template
  if type(content) == 'table' then
    content = table.concat(content, '\n')
  end
  return self
    :_compile(self.target, 'target')
    :next(function(target)
      if not target then
        return nil
      end
      self.target = target
      return self:_compile(content or '', 'content')
    end)
    :next(function(compiled_content)
      if not compiled_content then
        return nil
      end
      return vim.split(compiled_content, '\n', { plain = true })
    end)
end

---@return FeyCaptureTemplateDatetreeOpts
function Template:get_datetree_opts()
  ---@diagnostic disable-next-line: param-type-mismatch
  local datetree = vim.deepcopy(self.datetree)
  datetree = (type(datetree) == 'table' and datetree) or {}
  datetree.date = datetree.date or Date.now()
  datetree.tree_type = datetree.tree_type or 'day'
  return datetree
end

---The file a capture is written to: `target`, else `fey_default_notes_file`, else `agenda/inbox.fey` of
---the court. A target is a path (`~` works, a relative one is relative to the hollow of the working
---directory) or a reference to a file of a hollow: `court:notes/inbox.fey`, `court/agenda/inbox.fey`,
---`current:sub/todo.fey`. The file need not exist.
---@return string|nil path
---@return string|nil err
function Template:get_target()
  local target = self.target
  if not target or target == '' then target = require('fey.config').fey_default_notes_file end
  if not target or target == '' then
    local dir = require('fey.hollow.court').agenda_dir()
    if not dir then return nil, 'No capture target: set `fey_default_notes_file` or the `target` of the template' end
    return vim.fs.joinpath(dir, 'inbox.fey')
  end
  local tree = require('fey.hollow.tree')
  local ref = tree.parse_ref(target)
  if ref then
    local root, path, err = tree.resolve_ref(ref, tree.hollow_root_of(vim.fn.getcwd()))
    if not root or not path then return nil, err or ('no file in ' .. target) end
    return vim.fs.joinpath(root, path)
  end
  if target:match('^~') then return vim.fn.resolve(vim.fn.expand(target)) end
  if target:sub(1, 1) == '/' then return vim.fn.resolve(target) end
  local base = tree.hollow_root_of(vim.fn.getcwd()) or vim.fn.getcwd()
  return vim.fn.resolve(vim.fs.joinpath(base, target))
end

---@param lines string[]
---@return string[]
function Template:apply_properties_to_lines(lines)
  local empty_lines = self.properties.empty_lines

  for _ = 1, empty_lines.before do
    table.insert(lines, 1, '')
  end

  for _ = 1, empty_lines.after do
    table.insert(lines, '')
  end

  return lines
end

---@private
---@param content string
---@param content_type 'target' | 'content'
---@return FeyPromise<string | nil>
function Template:_compile(content, content_type)
  content = self:_compile_dates(content)
  if self._compile_hooks then
    for _, hook in ipairs(self._compile_hooks) do
      content = hook(content, content_type) --[[@as string]]
      if not content then
        return Promise.resolve(nil)
      end
    end
  end
  return self:_compile_datetree(content, content_type):next(function(compiled_content)
    if not compiled_content then
      return nil
    end
    return self:_compile_expansions(compiled_content):next(function(cnt)
      if not cnt then
        return nil
      end
      cnt = self:_compile_expressions(cnt)
      return self:_compile_prompts(cnt)
    end)
  end)
end

---@param content string
---@param content_type 'target' | 'content'
---@return FeyPromise<string | nil>
function Template:_compile_datetree(content, content_type)
  if
    not self.datetree
    or type(self.datetree) ~= 'table'
    or not self.datetree.time_prompt
    or content_type ~= 'target'
  then
    return Promise.resolve(content)
  end

  return Calendar.new({ date = Date.now(), title = 'Select datetree date' }):open():next(function(date)
    if date then
      self.datetree.date = date
      return content
    end
    return nil
  end)
end

---@param content string
---@return FeyPromise<string | nil>
function Template:_compile_expansions(content)
  local compiled_expansions = {}
  local proceed = true
  for exp in content:gmatch('%%([^%%]*)') do
    for expansion, compiler in pairs(expansions) do
      local match = ('%' .. exp):match(expansion)
      if match then
        table.insert(compiled_expansions, function()
          return Promise.resolve(compiler(match)):next(function(replacement)
            if not proceed or not replacement then
              return Promise.reject('canceled')
            end
            content = content:gsub(expansion, vim.pesc(replacement))
            return content
          end)
        end)
      end
    end
  end

  if #compiled_expansions == 0 then
    return Promise.resolve(content)
  end

  local result = Promise.resolve()
  for _, value in ipairs(compiled_expansions) do
    result = result:next(function()
      return value()
    end)
  end

  return result
    :next(function()
      if not proceed then
        return nil
      end
      return content
    end)
    :catch(function(err)
      if err == 'canceled' then
        return
      end
      error(err)
    end)
end

---@param content string
---@return string
function Template:_compile_dates(content)
  for exp in content:gmatch('%%<[^>]*>') do
    content = content:gsub(vim.pesc(exp), os.date(exp:sub(3, -2)))
  end
  return content
end

---@param content string
---@return FeyPromise<string>
function Template:_compile_prompts(content)
  local prepared_inputs = {}
  for exp in content:gmatch('%%%^%b{}') do
    local details = exp:match('%{(.*)%}')
    local parts = vim.split(details, '|')
    local title, default = parts[1], parts[2]
    local input = {
      fallback_value = default,
      exp = exp,
    }
    if #parts > 2 then
      input.prompt = string.format('%s [%s]: ', title, default)
      input.completion = function()
        local completion_items = vim.list_slice(parts, 3, #parts)
        return function(arg_lead)
          return vim.tbl_filter(function(v)
            return v:match('^' .. vim.pesc(arg_lead))
          end, completion_items)
        end
      end
    else
      input.prompt = default and string.format('%s [%s]:', title, default) or title .. ': '
    end
    table.insert(prepared_inputs, input)
  end

  if #prepared_inputs == 0 then
    return Promise.resolve(content)
  end

  return Promise.mapSeries(function(prepared_input)
    return Input.open(prepared_input.prompt, '', prepared_input.completion and prepared_input.completion() or nil)
      :next(function(response)
        if not response or #response == 0 then
          response = prepared_input.fallback_value
        end
        content = content:gsub(vim.pesc(prepared_input.exp), response)
      end)
  end, prepared_inputs):next(function()
    return content
  end)
end

function Template:_compile_expressions(content)
  for exp in content:gmatch('%%%b()') do
    local snippet = exp:match('%((.*)%)')
    local func = load(snippet)
    ---@diagnostic disable-next-line: param-type-mismatch
    local ok, response = pcall(func)
    if ok then
      content = content:gsub(vim.pesc(exp), response)
    end
  end
  return content
end

return Template
