-- Settings written in the notes, applied while you edit. A note, its hollow and the court can each carry
-- `nvim` tags (editor options, `colorscheme`) and `plugin` tags (options of a plugin); they are collected
-- into one table first and only the difference from what is applied now is touched, so a court wide colour
-- scheme is there until the hollow has its own, and the hollow's until the file has.
--
--   court                 <court>/.fey/config.fey
--   hollows above         <hollow>/.fey/config.fey, the outermost first
--   the hollow            <hollow>/.fey/config.fey
--   the file              its own tags
--
-- Later wins, key by key. Applying is on `settings.apply_on`: `load`, `enter` (the note becomes current),
-- `change` (typing, after `settings.debounce_ms`), `save`, and the mappings apply on request.
--
-- What a note may do is limited, see `fey.settings.options`: only options that are local to the buffer or the
-- window and do not run code, `colorscheme` and `background`; only registered plugins; only the options of this
-- plugin in `fey.settings.fey_options`. Hooks (`buf_enter`, `buf_leave`: Ex commands) exist only when
-- `settings.hooks` names their keys, because running the commands of a file from an unknown source runs code.
local config = require('fey.config')
local Options = require('fey.settings.options')
local Layers = require('fey.settings.layers')
local FeyOptions = require('fey.settings.fey_options')

local M = {}

---@class FeySettingsEffective
---@field nvim table<string, any>
---@field plugins table<string, table<string, any>>
---@field hooks table<string, string> `buf_enter` and `buf_leave` commands, when the hooks are named
---@field from table<string, string> where each setting came from
---@field layers FeySettingsLayer[]

-- State ---------------------------------------------------------------------------------------------------------

---@class FeySettingsState
---@field bufs table<integer, { applied: table<string, { value: any, baseline: any, scope: string }>, ignored: table<string, string> }>
---@field global { nvim: table<string, { value: any, baseline: any }>, fey: table<string, { baseline: any }>, plugins: table<string, table> }
local state = { bufs = {}, global = { nvim = {}, fey = {}, plugins = {} } }
M.state = state

local runtime = { enter = nil, hooks = nil }
local timers = {}
local file_cache = {}

---@return table
local function conf() return config.settings or {} end

-- The cascade -----------------------------------------------------------------------------------------------------

---@param root string
---@return string
local function config_path(root)
  return vim.fs.joinpath(root, (config.vault or {}).dirname or '.fey', conf().config_filename or 'config.fey')
end

---The config files that apply to a path, the widest first
---@param path? string
---@return string[]
function M.config_files(path)
  local tree = require('fey.hollow.tree')
  local roots, seen = {}, {}
  local function add(root)
    root = tree.realpath(root)
    if not seen[root] then
      seen[root] = true
      roots[#roots + 1] = root
    end
  end
  local court = require('fey.hollow.court').root()
  if court then add(court) end
  if conf().cascade ~= false and path and path ~= '' then
    local here = tree.hollow_root_of(path)
    if here then
      local above = tree.ancestors(here)
      for i = #above, 1, -1 do
        add(above[i])
      end
      add(here)
    end
  end
  return vim.tbl_map(config_path, roots)
end

---The layer of a config file: from its buffer when it is loaded (so unsaved edits count), else from the disk
---@param path string
---@return FeySettingsLayer|nil
local function file_layer(path)
  local bufnr = vim.fn.bufnr(path)
  if bufnr > 0 and vim.api.nvim_buf_is_loaded(bufnr) then
    local layer = Layers.read(bufnr, path)
    if layer then
      file_cache[path] = { layer = layer, tick = -1 }
      return layer
    end
    return file_cache[path] and file_cache[path].layer
  end
  local stat = vim.uv.fs_stat(path)
  if not stat then
    file_cache[path] = nil
    return nil
  end
  local stamp = stat.mtime.sec * 1e9 + stat.mtime.nsec
  local cached = file_cache[path]
  if cached and cached.stamp == stamp then return cached.layer end
  local fh = io.open(path, 'rb')
  if not fh then return nil end
  local text = fh:read('*a')
  fh:close()
  local layer = Layers.read(text, path)
  if layer then file_cache[path] = { layer = layer, stamp = stamp } end
  return layer or (cached and cached.layer)
end

---Everything the layers say, merged: later wins
---@param layers FeySettingsLayer[]
---@return FeySettingsEffective
local function merge(layers)
  local eff = { nvim = {}, plugins = {}, hooks = {}, from = {}, layers = layers }
  local hooks = conf().hooks or {}
  local hook_of = {}
  for hook, key in pairs(hooks) do
    if type(key) == 'string' and key ~= '' then hook_of[key] = hook end
  end
  for _, layer in ipairs(layers) do
    for key, value in pairs(layer.nvim) do
      if hook_of[key] then
        eff.hooks[hook_of[key]] = tostring(value)
      else
        eff.nvim[key] = value
        eff.from[key] = layer.source
      end
    end
    for name, opts in pairs(layer.plugins) do
      eff.plugins[name] = vim.tbl_deep_extend('force', eff.plugins[name] or {}, opts)
      for key in pairs(opts) do
        eff.from[name .. '.' .. key] = layer.source
      end
    end
  end
  return eff
end

---The settings of a buffer: the config files and the buffer's own tags
---@param bufnr integer
---@return FeySettingsEffective|nil nil when the buffer does not parse (it is mid-typing)
function M.effective(bufnr)
  local layers = {}
  local name = vim.api.nvim_buf_get_name(bufnr)
  for _, path in ipairs(M.config_files(name ~= '' and name or nil)) do
    -- a config file that is this buffer is its own layer, below
    if vim.uv.fs_realpath(path) ~= (name ~= '' and vim.uv.fs_realpath(name) or nil) then
      local layer = file_layer(path)
      if layer then layers[#layers + 1] = layer end
    end
  end
  local own = Layers.read(bufnr, 'file')
  if not own then return nil end
  layers[#layers + 1] = own
  return merge(layers)
end

-- Applying ------------------------------------------------------------------------------------------------------

local function warn(msg) vim.notify('fey: ' .. msg, vim.log.levels.WARN) end

---@param bufnr integer
local function buf_state(bufnr)
  state.bufs[bufnr] = state.bufs[bufnr] or { applied = {}, ignored = {} }
  return state.bufs[bufnr]
end

---Set an option of the buffer, or of every window that shows it
---@param bufnr integer
---@param info FeySettingOption
---@param value any
---@return any previous
local function set_local(bufnr, info, value)
  if info.scope == 'buf' then
    local previous = vim.bo[bufnr][info.name]
    vim.bo[bufnr][info.name] = value
    return previous
  end
  local previous
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    previous = previous == nil and vim.wo[win][info.name] or previous
    vim.wo[win][info.name] = value
  end
  return previous
end

---The buffer and window local options of the settings, with the others put back
---@param bufnr integer
---@param eff FeySettingsEffective
---@param additive? boolean do not put back what is not in the settings
local function apply_local(bufnr, eff, additive)
  local st = buf_state(bufnr)
  st.ignored = {}
  for key, value in pairs(eff.nvim) do
    if not Options.GLOBAL[key] then
      local ok, reason, info = Options.check(key, conf().allow)
      if not ok then
        st.ignored[key] = reason
      else
        local coerced = Options.coerce(info, value)
        if coerced == nil then
          st.ignored[key] = 'not a value of this option'
        else
          local record = st.applied[key]
          if not record or record.value ~= coerced then
            local ok_set, previous = pcall(set_local, bufnr, info, coerced)
            if ok_set then
              st.applied[key] = { value = coerced, baseline = record and record.baseline or previous, info = info }
            else
              st.ignored[key] = 'could not be set: ' .. tostring(previous)
            end
          end
        end
      end
    end
  end
  if additive then return end
  for key, record in pairs(st.applied) do
    if eff.nvim[key] == nil then
      pcall(set_local, bufnr, record.info, record.baseline)
      st.applied[key] = nil
    end
  end
end

---A colour scheme name is a plain name: it goes into an Ex command
---@param name any
---@return boolean
local function valid_scheme(name) return type(name) == 'string' and name:match('^[%w_%-%.]+$') ~= nil end

---`colorscheme` and `background`, which belong to the whole editor: applied while the note is current
---@param eff FeySettingsEffective
---@param ignored table<string, string>
---@param additive? boolean
local function apply_global(eff, ignored, additive)
  local g = state.global.nvim
  local function set(key, value)
    local record = g[key]
    -- what is recorded must still be what is set: a colour scheme can change the background under us
    local actual = key == 'colorscheme' and vim.g.colors_name or vim.o.background
    if record and record.value == value and actual == value then return end
    if key == 'colorscheme' then
      if not valid_scheme(value) then
        ignored[key] = 'not a colour scheme name'
        return
      end
      local baseline = record and record.baseline or vim.g.colors_name
      if vim.g.colors_name ~= value and not pcall(vim.cmd.colorscheme, value) then
        ignored[key] = 'no such colour scheme'
        return
      end
      g[key] = { value = value, baseline = baseline }
    else -- background
      if value ~= 'dark' and value ~= 'light' then
        ignored[key] = 'dark or light'
        return
      end
      g[key] = { value = value, baseline = record and record.baseline or vim.o.background }
      -- changing the background loads the current colour scheme again: when a new one follows, do not
      local loading_new = eff.nvim.colorscheme ~= nil
        and valid_scheme(eff.nvim.colorscheme)
        and vim.g.colors_name ~= eff.nvim.colorscheme
      local name = vim.g.colors_name
      if loading_new then vim.g.colors_name = nil end
      vim.o.background = value
      if loading_new then vim.g.colors_name = name end
    end
  end
  -- the background first: changing it loads the colour scheme again
  for _, key in ipairs({ 'background', 'colorscheme' }) do
    if eff.nvim[key] ~= nil then set(key, eff.nvim[key]) end
  end
  if additive then return end
  for key, record in pairs(g) do
    if eff.nvim[key] == nil then
      if key == 'colorscheme' and record.baseline and valid_scheme(record.baseline) then
        pcall(vim.cmd.colorscheme, record.baseline)
      elseif key == 'background' and record.baseline then
        vim.o.background = record.baseline
      end
      g[key] = nil
    end
  end
end

---@param opts table
local function reset_config_caches()
  config.todo_keywords = nil
  config.priorities = nil
end

---The built in plugin: the options of this one, from the white list
M.plugin_handlers = {
  fey = {
    apply = function(opts, ignored, additive)
      local applied = state.global.fey
      for key, value in pairs(opts) do
        if not FeyOptions.allowed(key) then
          ignored['fey.' .. key] = 'not an option a note may change'
        else
          local record = applied[key]
          local current = config.opts[key]
          if not record then
            applied[key] = { baseline = vim.deepcopy(current), value = vim.deepcopy(value) }
            config.opts[key] = type(value) == 'table'
                and type(current) == 'table'
                and vim.tbl_deep_extend('force', vim.deepcopy(current), value)
              or value
          elseif not vim.deep_equal(record.value, value) then
            record.value = vim.deepcopy(value)
            local base = record.baseline
            config.opts[key] = type(value) == 'table'
                and type(base) == 'table'
                and vim.tbl_deep_extend('force', vim.deepcopy(base), value)
              or value
          end
        end
      end
      if not additive then
        for key, record in pairs(applied) do
          if opts[key] == nil then
            config.opts[key] = record.baseline
            applied[key] = nil
          end
        end
      end
      reset_config_caches()
    end,
  },
}

---A plugin that notes may configure: `apply(opts)` is called with the merged options when they change, and
---`restore()` (when there is one) when no note asks for options any more. The options are data from the note,
---a handler is code of yours, which is why this is the only way in.
---@param name string
---@param handler { apply: fun(opts: table), restore?: fun() }
function M.register(name, handler) M.plugin_handlers[name] = handler end

---@param name string
---@return table|nil
local function handler_of(name)
  local custom = (conf().plugins or {})[name]
  if type(custom) == 'function' then return { apply = custom } end
  return custom or M.plugin_handlers[name]
end

---@param eff FeySettingsEffective
---@param ignored table<string, string>
---@param additive? boolean
local function apply_plugins(eff, ignored, additive)
  local applied = state.global.plugins
  for name, opts in pairs(eff.plugins) do
    local handler = handler_of(name)
    if not handler then
      ignored['plugin ' .. name] = 'not a registered plugin'
    elseif name == 'fey' then
      handler.apply(opts, ignored, additive)
      applied[name] = true
    elseif not vim.deep_equal(applied[name], opts) then
      local ok, err = pcall(handler.apply, vim.deepcopy(opts))
      if ok then
        applied[name] = vim.deepcopy(opts)
      else
        warn(('plugin %s: %s'):format(name, err))
      end
    end
  end
  if additive then return end
  for name in pairs(applied) do
    if eff.plugins[name] == nil then
      local handler = handler_of(name)
      if name == 'fey' and handler then handler.apply({}, ignored, false) end
      if name ~= 'fey' and handler and handler.restore then pcall(handler.restore) end
      applied[name] = nil
    end
  end
end

---Apply the settings of a buffer
---@param bufnr? integer
---@param opts? { layer?: FeySettingsLayer } `layer`: apply just that on top of what is applied, change nothing else
---@return FeySettingsEffective|nil
function M.apply(bufnr, opts)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  opts = opts or {}
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].filetype ~= 'fey' then return nil end
  local eff
  if opts.layer then
    eff = merge({ opts.layer })
  else
    eff = M.effective(bufnr)
  end
  -- a parse error (mid typing) leaves everything as it is
  if not eff then return nil end
  local additive = opts.layer ~= nil
  apply_local(bufnr, eff, additive)
  if bufnr == vim.api.nvim_get_current_buf() then
    local st = buf_state(bufnr)
    apply_global(eff, st.ignored, additive)
    apply_plugins(eff, st.ignored, additive)
  end
  if not additive then buf_state(bufnr).effective = eff end
  return eff
end

-- Hooks ------------------------------------------------------------------------------------------------------------

---Run the commands of the hooks of a buffer (`buf_enter`, `buf_leave`), when the hooks are named in the
---setup. Without names there is nothing to run.
---@param bufnr integer
---@param which? string `buf_enter` or `buf_leave`, both when missing
---@param eff? FeySettingsEffective
function M.run_hooks(bufnr, which, eff)
  if not next(conf().hooks or {}) then return end
  eff = eff or (state.bufs[bufnr] and state.bufs[bufnr].effective) or M.effective(bufnr)
  if not eff then return end
  for _, hook in ipairs(which and { which } or { 'buf_enter', 'buf_leave' }) do
    local command = eff.hooks[hook]
    if command and command ~= '' then
      local ok, err = pcall(vim.cmd, command)
      if not ok then warn(('%s: %s'):format(hook, err)) end
    end
  end
end

-- Triggers ---------------------------------------------------------------------------------------------------------

---@param event 'load'|'enter'|'change'|'save'
---@return boolean
local function triggers(event)
  if event == 'enter' and runtime.enter ~= nil then return runtime.enter end
  return vim.tbl_contains(conf().apply_on or { 'load', 'enter', 'change' }, event)
end

local function hooks_on()
  if runtime.hooks ~= nil then return runtime.hooks end
  return true
end

---Switch applying on entering a buffer on or off for this session (`fey_toggle_apply_all_settings_at_buffer_enter`)
---@return boolean
function M.toggle_apply_at_enter()
  runtime.enter = not triggers('enter')
  vim.notify('fey: settings are ' .. (runtime.enter and 'applied' or 'not applied') .. ' when a buffer is entered')
  return runtime.enter
end

---Switch running the buffer commands on enter and leave
---@return boolean
function M.toggle_hooks_at_enter()
  runtime.hooks = not hooks_on()
  vim.notify('fey: buffer commands are ' .. (runtime.hooks and 'run' or 'not run') .. ' when a buffer is entered or left')
  return runtime.hooks
end

local function is_config_file(name)
  local filename = conf().config_filename or 'config.fey'
  local dir = (config.vault or {}).dirname or '.fey'
  return name:sub(-#(dir .. '/' .. filename)) == dir .. '/' .. filename
end

function M.setup()
  local group = vim.api.nvim_create_augroup('FeySettings', { clear = true })
  local function later(buf, fn)
    if timers[buf] then timers[buf]:stop() end
    timers[buf] = vim.defer_fn(function()
      timers[buf] = nil
      if vim.api.nvim_buf_is_valid(buf) then fn() end
    end, conf().debounce_ms or 300)
  end

  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = 'fey',
    callback = function(args)
      if vim.b[args.buf].fey_settings_loaded then return end
      vim.b[args.buf].fey_settings_loaded = true
      if triggers('load') then later(args.buf, function() M.apply(args.buf) end) end
    end,
  })
  vim.api.nvim_create_autocmd({ 'BufEnter', 'BufWinEnter' }, {
    group = group,
    pattern = { '*.fey' },
    callback = function(args)
      if triggers('enter') then
        later(args.buf, function()
          local eff = M.apply(args.buf)
          if args.event == 'BufEnter' and hooks_on() and eff then M.run_hooks(args.buf, 'buf_enter', eff) end
        end)
      end
    end,
  })
  vim.api.nvim_create_autocmd('BufLeave', {
    group = group,
    pattern = { '*.fey' },
    callback = function(args)
      if hooks_on() and next(conf().hooks or {}) then M.run_hooks(args.buf, 'buf_leave') end
    end,
  })
  vim.api.nvim_create_autocmd({ 'TextChanged', 'InsertLeave' }, {
    group = group,
    pattern = { '*.fey' },
    callback = function(args)
      if triggers('change') or is_config_file(args.file) then
        later(args.buf, function() M.apply(vim.api.nvim_get_current_buf()) end)
      end
    end,
  })
  vim.api.nvim_create_autocmd('BufWritePost', {
    group = group,
    pattern = { '*.fey' },
    callback = function(args)
      if triggers('save') or is_config_file(args.file) then
        later(args.buf, function() M.apply(vim.api.nvim_get_current_buf()) end)
      end
    end,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    callback = function(args) state.bufs[args.buf] = nil end,
  })
  vim.api.nvim_create_user_command('FeySettings', function() M.show() end, {
    desc = 'Show the settings of this note: where they come from, and what was ignored',
  })
end

-- Mappings and reports -----------------------------------------------------------------------------------------

---The tag under the cursor, as a layer
---@return FeySettingsLayer|nil
local function layer_at_cursor()
  local bufnr = vim.api.nvim_get_current_buf()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  pcall(function() vim.treesitter.get_parser(bufnr, 'fey'):parse() end)
  local ok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr, pos = { row - 1, col } })
  while ok and node do
    local t = node:type()
    if t == 'scope_tag' or t == 'line_tag' or t == 'block_tag' or t == 'pair_tag' then return Layers.read_tag(bufnr, node) end
    node = node:parent()
  end
end

---Apply every setting of the current buffer now (`fey_apply_all_settings`)
function M.apply_current()
  local eff = M.apply(vim.api.nvim_get_current_buf())
  if not eff then return vim.notify('fey: the note does not parse, settings left as they are', vim.log.levels.WARN) end
  local ignored = buf_state(vim.api.nvim_get_current_buf()).ignored
  local n = vim.tbl_count(ignored)
  vim.notify(('fey: settings applied%s'):format(n > 0 and ('; %d ignored, see :FeySettings'):format(n) or ''))
end

---Apply the tag under the cursor on top of what is applied (`fey_apply_settings_at_tag`)
function M.apply_tag_at_cursor()
  local layer = layer_at_cursor()
  if not layer or (not next(layer.nvim) and not next(layer.plugins)) then
    return vim.notify('fey: no nvim or plugin tag here', vim.log.levels.INFO)
  end
  M.apply(vim.api.nvim_get_current_buf(), { layer = layer })
end

---Run the buffer commands of the note now (`fey_run_all_buffer_commands`)
function M.run_hooks_now()
  if not next(conf().hooks or {}) then
    return vim.notify('fey: buffer commands are off: name the keys in settings.hooks to use them', vim.log.levels.INFO)
  end
  M.run_hooks(vim.api.nvim_get_current_buf())
end

---Run the buffer command of the tag under the cursor (`fey_run_buffer_commands_at_tag`)
function M.run_hooks_at_tag()
  if not next(conf().hooks or {}) then
    return vim.notify('fey: buffer commands are off: name the keys in settings.hooks to use them', vim.log.levels.INFO)
  end
  local layer = layer_at_cursor()
  if not layer then return vim.notify('fey: no tag here', vim.log.levels.INFO) end
  M.run_hooks(vim.api.nvim_get_current_buf(), nil, merge({ layer }))
end

---The lines of what the settings of a buffer are and where each comes from
---@param bufnr? integer
---@return string[]
function M.report(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local eff = M.effective(bufnr)
  if not eff then return { 'The note does not parse: nothing is applied.' } end
  local lines = {
    'Fey settings of ' .. (vim.api.nvim_buf_get_name(bufnr) ~= '' and vim.fn.fnamemodify(
      vim.api.nvim_buf_get_name(bufnr),
      ':~'
    ) or 'this buffer'),
    '',
    'Layers, the widest first:',
  }
  for _, layer in ipairs(eff.layers) do
    lines[#lines + 1] = ('  %s (%d tag%s)'):format(layer.source, #layer.tags, #layer.tags == 1 and '' or 's')
  end
  local keys = vim.tbl_keys(eff.nvim)
  table.sort(keys)
  if #keys > 0 then
    lines[#lines + 1] = ''
    lines[#lines + 1] = 'nvim:'
  end
  for _, key in ipairs(keys) do
    lines[#lines + 1] = ('  %s = %s   (%s)'):format(key, (vim.inspect(eff.nvim[key]):gsub('\n', ' ')), eff.from[key] or '?')
  end
  local names = vim.tbl_keys(eff.plugins)
  table.sort(names)
  for _, name in ipairs(names) do
    lines[#lines + 1] = ''
    lines[#lines + 1] = 'plugin ' .. name .. ':'
    local opts = vim.tbl_keys(eff.plugins[name])
    table.sort(opts)
    for _, key in ipairs(opts) do
      lines[#lines + 1] = ('  %s = %s   (%s)'):format(
        key,
        (vim.inspect(eff.plugins[name][key]):gsub('\n', ' ')),
        eff.from[name .. '.' .. key] or '?'
      )
    end
  end
  local ignored = state.bufs[bufnr] and state.bufs[bufnr].ignored or {}
  local ik = vim.tbl_keys(ignored)
  table.sort(ik)
  if #ik > 0 then
    lines[#lines + 1] = ''
    lines[#lines + 1] = 'Ignored:'
  end
  for _, key in ipairs(ik) do
    lines[#lines + 1] = ('  %s: %s'):format(key, ignored[key])
  end
  return lines
end

function M.show()
  vim.api.nvim_echo(vim.tbl_map(function(l) return { l .. '\n' } end, M.report()), true, {})
end

return M
