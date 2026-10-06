-- Fey data serialization for database files (README section VII).
--
-- A database file is one `[ table ]#` block tag whose body is a nested list:
--
--   [ table ]#
--       name_:  Projects
--       views_:
--           -
--               name_:  Table
--               columns_:
--                   -
--                       prop_:  file.name
--
-- Keys are bullets (`key_:`), so they are plain identifiers; anything that is not a
-- safe inline scalar is written as a fenced block, which keeps its text exactly.
local extract = require('fey.vault.extract')

local M = {}

local INDENT = 4

-- keys are written in this order first, then alphabetically
local KEY_ORDER = {
  'name', 'version', 'kind', 'type', 'mode', 'prop', 'op', 'value', 'expr', 'display', 'width', 'summary', 'dir',
  'limit', 'row_height', 'freeze', 'filters', 'formulas', 'properties', 'columns', 'sort', 'group', 'items', 'views',
}
local KEY_RANK = {}
for i, k in ipairs(KEY_ORDER) do
  KEY_RANK[k] = i
end

---@param s string
---@return boolean
local function inline_safe(s)
  if s == '' or s:find('[\n\r\t"\'\\#`]') then return false end
  if s:find('^%s') or s:find('%s$') or s:find('%s%s') then return false end
  if s:find('^[%-%+%*%.,:;!%?/\\\'"`=~%^@&#%$%%%[%](){}<>]') then return false end -- would read as a bullet or heading
  if s:find('[%[{(<][%s%p]') or s:find('[%s%p][%]})>]') then return false end -- tag shaped
  if s:find('[%[%]{}]') then return false end
  return true
end

---Would reading this text back give a different type?
---@param s string
local function ambiguous(s) return type(extract.scalar(s)) ~= 'string' or extract.scalar(s) ~= s end

---@param v any
---@return string|nil text inline representation, nil when a fenced block is needed
local function scalar_inline(v)
  local t = type(v)
  if t == 'boolean' then return tostring(v) end
  if t == 'number' then
    if v % 1 == 0 and math.abs(v) < 1e15 then return ('%d'):format(v) end
    return ('%.14g'):format(v)
  end
  if t == 'string' then
    if v == '' then return '""' end
    if inline_safe(v) then
      if ambiguous(v) then return '"' .. v .. '"' end
      return v
    end
    if not v:find('[\n\r"]') and v:find('%S') and not v:find('^%s') and not v:find('%s$') then
      -- quoted keeps the text, but only when the line itself stays harmless
      if not v:find('[%[%]{}<>]') and not v:find('^%p') then return '"' .. v .. '"' end
    end
  end
  return nil
end

---@param v any
local function is_list(v) return type(v) == 'table' and (vim.islist(v) and next(v) ~= nil) end
---@param v any
local function is_map(v) return type(v) == 'table' and not vim.islist(v) end

---@param v any
---@return boolean
local function empty(v) return v == nil or v == vim.NIL or (type(v) == 'table' and next(v) == nil) end

---@param s string
---@return string fence
local function fence_for(s)
  local longest = 2
  for run in s:gmatch('`+') do
    longest = math.max(longest, #run)
  end
  return ('`'):rep(longest + 1)
end

local emit_value

---@param key_text string `name_:` or `-`
---@param v any
---@param pad string
---@param out string[]
local function emit_entry(key_text, v, pad, out)
  if type(v) == 'table' then
    out[#out + 1] = pad .. key_text
    emit_value(v, pad .. (' '):rep(INDENT), out)
    return
  end
  local inline = scalar_inline(v)
  if inline then
    out[#out + 1] = pad .. key_text .. '  ' .. inline
    return
  end
  local text = tostring(v)
  local fence = fence_for(text)
  local inner = pad .. (' '):rep(INDENT)
  out[#out + 1] = pad .. key_text
  out[#out + 1] = inner .. fence
  for _, line in ipairs(vim.split(text, '\n', { plain = true })) do
    out[#out + 1] = line == '' and '' or (inner .. line)
  end
  out[#out + 1] = inner .. fence
end

---@param v table
---@param pad string
---@param out string[]
function emit_value(v, pad, out)
  if is_list(v) then
    for _, item in ipairs(v) do
      emit_entry('-', item, pad, out)
    end
  elseif is_map(v) then
    local keys = {}
    for k, item in pairs(v) do
      if not empty(item) or type(item) ~= 'table' then
        if item ~= nil and item ~= vim.NIL then keys[#keys + 1] = k end
      end
    end
    table.sort(keys, function(a, b)
      local ra, rb = KEY_RANK[a] or math.huge, KEY_RANK[b] or math.huge
      if ra ~= rb then return ra < rb end
      return a < b
    end)
    for _, k in ipairs(keys) do
      assert(k:match('^[%w_]+$'), 'database keys must be identifiers: ' .. k)
      emit_entry(k .. '_:', v[k], pad, out)
    end
  end
end

---Encode data as the text of a database file
---@param data table
---@return string
function M.encode(data)
  local out = { '[ table ]#' }
  emit_value(data, (' '):rep(INDENT), out)
  return table.concat(out, '\n') .. '\n'
end

---Decode a database file
---@param src string
---@return table|nil data
---@return string[] errors
function M.decode(src)
  local meta = extract.extract(src)
  local data = meta.data
  if type(data) ~= 'table' then return nil, meta.errors end
  return data, meta.errors
end

---Lines of one `key_:` entry (nested lists for arrays), at column 0
---@param key string
---@param value any
---@return string[]
function M.entry_lines(key, value)
  local out = {}
  emit_entry(key .. '_:', value, '', out)
  return out
end

M.scalar_inline = scalar_inline

return M
