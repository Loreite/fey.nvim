-- The list of default mappings for the README, made from `config/defaults.lua` and the descriptions of the
-- mapping entries (`config/mappings`), so it cannot drift from what is mapped.
--
--   nvim -l scripts/gen_mappings.lua          rewrite the generated part of README.fey
--   nvim -l scripts/gen_mappings.lua --check  fail when it is out of date
local M = {}

M.BEGIN = '-- begin generated: mappings (scripts/gen_mappings.lua) --'
M.END = '-- end generated: mappings --'

local GROUPS = {
  { 'global', 'Anywhere' },
  { 'fey', 'In Fey files' },
  { 'agenda', 'In the agenda' },
  { 'capture', 'In the capture window' },
  { 'note', 'In the closing note window' },
  { 'text_objects', 'Text objects' },
}

---@param value any
---@return string
local function keys_of(value)
  if type(value) == 'table' then return table.concat(value, ' ') end
  return tostring(value)
end

---@param text string
---@return string
local function cell(text) return (text:gsub('|', '\\|')) end

---Names that have a default mapping but no mapping entry: they do nothing yet
---@return string[]
function M.orphans()
  local defaults = require('fey.config.defaults').mappings
  local entries = require('fey.config.mappings')
  local out = {}
  for _, g in ipairs(GROUPS) do
    for name, value in pairs(defaults[g[1]] or {}) do
      if value ~= '' and value ~= false and not (entries[g[1]] or {})[name] then out[#out + 1] = g[1] .. '.' .. name end
    end
  end
  table.sort(out)
  return out
end

---Rows of one group: key, what it does, the name to use in the configuration
---@param group string
---@return string[][]
function M.rows(group)
  local defaults = require('fey.config.defaults').mappings[group] or {}
  local entries = require('fey.config.mappings')[group] or {}
  local rows = {}
  for name, value in pairs(defaults) do
    local entry = entries[name]
    if entry and value ~= '' and value ~= false then
      local desc = entry.help_desc or (entry.opts and entry.opts.desc) or name
      rows[#rows + 1] = { keys_of(value), desc, name }
    end
  end
  table.sort(rows, function(a, b) return a[3] < b[3] end)
  return rows
end

---A Fey table
---@param rows string[][]
---@param headers string[]
---@return string[]
local function table_lines(rows, headers)
  local widths = {}
  for i, h in ipairs(headers) do
    widths[i] = #h
  end
  for _, row in ipairs(rows) do
    for i, c in ipairs(row) do
      widths[i] = math.max(widths[i], vim.api.nvim_strwidth(cell(c)))
    end
  end
  local function line(cells, fill)
    local parts = {}
    for i, c in ipairs(cells) do
      c = cell(c)
      parts[i] = ' ' .. c .. string.rep(fill or ' ', widths[i] - vim.api.nvim_strwidth(c)) .. ' '
    end
    return '|' .. table.concat(parts, '|') .. '|'
  end
  local out = { line(headers) }
  local sep = {}
  for i, w in ipairs(widths) do
    sep[i] = string.rep('=', w)
  end
  out[#out + 1] = '+' .. table.concat(
    vim.tbl_map(function(s) return '=' .. s .. '=' end, sep),
    '+'
  ) .. '+'
  for _, row in ipairs(rows) do
    out[#out + 1] = line(row)
  end
  return out
end

M.table_lines = table_lines

---The generated lines, markers included
---@return string[]
function M.render()
  local prefix = require('fey.config.defaults').mappings.prefix
  local out = {
    M.BEGIN,
    '',
    ('`<prefix>` is `%s` unless `mappings.prefix` says otherwise. A mapping is changed or turned off in'):format(prefix),
    'the setup, under the name in the last column: `mappings = { fey = { fey_refile = "<prefix>R" } }`, or',
    '`false` to turn it off.',
    '',
  }
  for _, g in ipairs(GROUPS) do
    local rows = M.rows(g[1])
    if #rows > 0 then
      out[#out + 1] = g[2] .. ':'
      out[#out + 1] = ''
      vim.list_extend(out, table_lines(rows, { 'keys', 'does', 'name' }))
      out[#out + 1] = ''
    end
  end
  out[#out + 1] = M.END
  return out
end

---Replace the generated part of a file's lines
---@param lines string[]
---@return string[]|nil new
---@return string|nil err
function M.replace(lines)
  local first, last
  for i, l in ipairs(lines) do
    if l == M.BEGIN then first = i end
    if l == M.END then last = i end
  end
  if not first or not last or last < first then return nil, 'the markers are not in the file' end
  local out = vim.list_slice(lines, 1, first - 1)
  vim.list_extend(out, M.render())
  vim.list_extend(out, vim.list_slice(lines, last + 1))
  return out
end

return M
