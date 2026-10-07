-- The reference of the options: one row for every option of `config/defaults.lua`, with what `config/_meta.lua` says about it, and the two
-- things a user wants to know before putting an option in a note: whether a `plugin` tag may set it, and whether the change takes effect at once.
-- The white list is `settings/fey_options.lua` (the code decides, so this cannot drift); an option that is on it is applied as soon as the note
-- is applied, one that is not is read when the plugin is set up.
local generated = require('fey.docs.generated')

local M = {}

---Read a type from the start of a string: up to the first blank that is not inside brackets, with the unions (` | `) joined
---@param rest string
---@return string type
---@return string remainder
local function read_type(rest)
  local function one(str)
    local depth, i = 0, 1
    while i <= #str do
      local c = str:sub(i, i)
      if c == '<' or c == '{' or c == '(' or c == '[' then
        depth = depth + 1
      elseif c == '>' or c == '}' or c == ')' or c == ']' then
        depth = depth - 1
      elseif c:match('%s') and depth <= 0 then
        break
      end
      i = i + 1
    end
    return str:sub(1, i - 1), str:sub(i)
  end
  local ty, remainder = one(rest)
  while remainder:match('^%s*|%s*%S') do
    local more
    more, remainder = one(remainder:gsub('^%s*|%s*', '', 1))
    ty = ty .. ' | ' .. more
  end
  return ty, remainder
end

---The descriptions of `_meta.lua`: name -> { type, description }
---@return table<string, { type: string, desc: string, count: integer }>
local function meta()
  local out = {}
  for _, path in ipairs(vim.api.nvim_get_runtime_file('lua/fey/config/_meta.lua', false)) do
    for line in io.lines(path) do
      local name, rest = line:match('^%-%-%-@field ([%w_]+)%??%s+(.*)$')
      if name then
        local ty, remainder = read_type(rest)
        local entry = out[name] or { count = 0 }
        entry.count = entry.count + 1
        entry.type = ty
        entry.desc = vim.trim(remainder)
        out[name] = entry
      end
    end
  end
  return out
end

---@param value any
---@return string
local function show(value)
  local text = vim.inspect(value, { newline = ' ', indent = '' }):gsub('%s+', ' ')
  if #text > 48 then text = text:sub(1, 45) .. '...' end
  return text
end

---@param value any
---@return boolean
local function is_group(value)
  if type(value) ~= 'table' or next(value) == nil then return false end
  for k in pairs(value) do
    if type(k) ~= 'string' then return false end
  end
  return true
end

-- groups whose keys are not a fixed set of options
local FREE = { fey_capture_templates = true, fey_agenda_custom_commands = true, fey_custom_exports = true, tag_handlers = true, tag_exports = true, fey_link_schemes = true }
-- groups that are told elsewhere
local SKIP = { mappings = true }

---Every option, nested ones as `group.key`, in the order of the names
---@return { name: string, value: any, top: string }[]
function M.options()
  local defaults = require('fey.config.defaults')
  local names = vim.tbl_keys(defaults)
  table.sort(names)
  local out = {}
  local function walk(prefix, tbl, top, depth)
    local keys = vim.tbl_keys(tbl)
    table.sort(keys)
    for _, key in ipairs(keys) do
      local value = tbl[key]
      local name = prefix == '' and key or (prefix .. '.' .. key)
      if is_group(value) and depth < 3 and not FREE[key] and not FREE[top] then
        walk(name, value, top, depth + 1)
      else
        out[#out + 1] = { name = name, value = value, top = top }
      end
    end
  end
  for _, name in ipairs(names) do
    if not SKIP[name] then
      local value = defaults[name]
      if is_group(value) and not FREE[name] then
        walk(name, value, name, 1)
      else
        out[#out + 1] = { name = name, value = value, top = name }
      end
    end
  end
  return out
end

---@param top string
---@return boolean
local function settable(top)
  return require('fey.settings.fey_options').allowed(top)
end

---The generated lines: one item for each option
---@return string[]
function M.render()
  local info = meta()
  local items = {}
  for _, option in ipairs(M.options()) do
    local last = option.name:match('([^.]+)$')
    local entry = info[option.name] or (info[last] and info[last].count == 1 and info[last]) or nil
    local ty = entry and entry.type or type(option.value)
    if ty == '' then ty = type(option.value) end
    local desc = generated.prose(entry and entry.desc or '')
    -- the meta says the default again at the end of the description
    desc = desc:gsub('%s*Default:.*$', '')
    local can = settable(option.top)
    items[#items + 1] = ('-  `%s`  (%s, default `%s`; a note may set it: %s)%s'):format(
      option.name,
      generated.prose(ty),
      generated.prose(show(option.value)),
      can and 'yes, at once' or 'no, read when the plugin is set up',
      desc ~= '' and ('  ' .. desc) or ''
    )
  end
  local out = {
    ('%d options. "A note may set it" is the white list of the `plugin` tag (`fey.settings.fey_options`): a `plugin` tag, in the court, a hollow or a note, can set'):format(#items),
    'those, and the change takes effect as soon as it is applied; the others are read when the plugin is set up, so they are written in the setup.',
    '',
  }
  vim.list_extend(out, items)
  return out
end

---The options a `nvim` tag may not set until the setup allows them, with why
---@return string[]
function M.render_denied()
  local options = require('fey.settings.options')
  local names = vim.tbl_keys(options.UNSAFE)
  table.sort(names)
  local rows = {}
  for _, name in ipairs(names) do
    rows[#rows + 1] = { '`' .. name .. '`', options.UNSAFE[name] }
  end
  local global = vim.tbl_keys(options.GLOBAL)
  table.sort(global)
  local out = {
    'The options of the editor that a `nvim` tag may not set, because they run what is in them, call a program or reach outside the editor. `settings.allow` in the setup opens one by name.',
    '',
  }
  vim.list_extend(out, generated.table(rows, { 'option', 'why it is denied' }))
  out[#out + 1] = ''
  out[#out + 1] = ('The only global options a note may set (they change the whole editor while the note is current): %s. Every other option has to be local to the buffer or the window.'):format(
    table.concat(vim.tbl_map(function(n) return '`' .. n .. '`' end, global), ', ')
  )
  return out
end

return M
