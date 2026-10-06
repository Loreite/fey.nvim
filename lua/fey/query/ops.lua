-- Field access, operators and string conversion shared by the evaluator and the
-- function library.
local V = require('fey.query.values')

local NULL = V.NULL
local M = {}

local WEEKDAYS = { 'Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday' }
local MONTHS = {
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
}
M.WEEKDAYS, M.MONTHS = WEEKDAYS, MONTHS

---Dataview lets `Some Key` be reached as `some-key`
---@param key string
function M.normalize_key(key) return (key:lower():gsub('%s+', '-')) end

---ISO week number and year
---@param ts number
---@return integer week, integer year
local function iso_week(ts)
  local t = os.date('*t', math.floor(ts)) --[[@as osdateparam]]
  local wday = (t.wday + 5) % 7 -- Monday = 0
  local thursday = os.time({ year = t.year, month = t.month, day = t.day - wday + 3, hour = 12 })
  local ty = os.date('*t', thursday) --[[@as osdateparam]]
  return math.floor((ty.yday - 1) / 7) + 1, ty.year
end
M.iso_week = iso_week

local function date_field(d, name)
  local f = V.date_fields(d)
  if name == 'year' then return f.year end
  if name == 'month' then return f.month end
  if name == 'day' then return f.day end
  if name == 'hour' then return f.hour end
  if name == 'minute' then return f.min end
  if name == 'second' then return f.sec end
  if name == 'millisecond' then return math.floor((d.ts % 1) * 1000 + 0.5) end
  if name == 'weekday' then return (f.wday + 5) % 7 + 1 end
  if name == 'week' then return (iso_week(d.ts)) end
  if name == 'weekyear' then return select(2, iso_week(d.ts)) end
  if name == 'ts' then return d.ts end
  return NULL
end

---Field access (`a.b`, `a["b"]`). Lists swizzle: `rows.file.name` maps over the list.
---@param obj any
---@param key any
---@return any
function M.get(obj, key)
  if V.is_null(obj) then return NULL end
  local t = V.typeof(obj)

  if t == 'object' then
    local v = obj[key]
    if v == nil and type(key) == 'string' then
      -- `Some Key` is reachable as `some-key`
      local norm = M.normalize_key(key)
      for _, k in ipairs(V.keys(obj)) do
        if M.normalize_key(k) == norm then
          v = obj[k]
          break
        end
      end
    end
    if v == nil then return NULL end
    return v
  end

  if t == 'array' then
    if type(key) == 'number' then
      if key < 0 then key = #obj + key end
      local v = obj[key + 1]
      return v == nil and NULL or v
    end
    if key == 'length' then return #obj end
    local out = {}
    for i, item in ipairs(obj) do
      out[i] = M.get(item, key)
    end
    return V.list(out)
  end

  if t == 'string' then
    if type(key) == 'number' then
      local ch = obj:sub(key + 1, key + 1)
      return ch ~= '' and ch or NULL
    end
    if key == 'length' then return #obj end
    return NULL
  end

  if t == 'date' then return date_field(obj, key) end
  if t == 'duration' then
    local norm = V.duration_from_ms(V.duration_ms(obj))
    local v = norm[key]
    return v == nil and NULL or v
  end
  if t == 'link' then
    if key == 'path' or key == 'display' or key == 'subpath' or key == 'embed' then
      local v = obj[key]
      return v == nil and NULL or v
    end
    if key == 'type' then return 'file' end
  end
  return NULL
end

local DATE_FORMAT = '%Y-%m-%d'
local DATETIME_FORMAT = '%Y-%m-%d %H:%M:%S'

---@param d table
function M.date_tostring(d)
  local out = os.date(d.time and DATETIME_FORMAT or DATE_FORMAT, math.floor(d.ts)) --[[@as string]]
  return out
end

---Plain text of a value (links are rendered by the renderer, which knows the link syntax)
---@param v any
---@return string
function M.tostring(v)
  local t = V.typeof(v)
  if t == 'null' then return 'null' end
  if t == 'string' then return v end
  if t == 'boolean' then return tostring(v) end
  if t == 'number' then
    if v % 1 == 0 and math.abs(v) < 1e15 then return ('%d'):format(v) end
    return (('%.10g'):format(v))
  end
  if t == 'date' then return M.date_tostring(v) end
  if t == 'duration' then return V.duration_tostring(v) end
  if t == 'link' then return v.display or v.path end
  if t == 'array' then
    local parts = {}
    for i, item in ipairs(v) do
      parts[i] = M.tostring(item)
    end
    return '[' .. table.concat(parts, ', ') .. ']'
  end
  if t == 'object' then
    local parts = {}
    for _, k in ipairs(V.keys(v)) do
      parts[#parts + 1] = k .. ': ' .. M.tostring(v[k])
    end
    return '{ ' .. table.concat(parts, ', ') .. ' }'
  end
  return '<' .. t .. '>'
end

-- Operators --------------------------------------------------------------------

local function both(a, b, ta, tb) return V.typeof(a) == ta and V.typeof(b) == tb end

---@param op string
---@param a any
---@param b any
---@return any
function M.binary(op, a, b)
  if op == 'and' then return V.truthy(a) and V.truthy(b) end
  if op == 'or' then return V.truthy(a) or V.truthy(b) end
  if op == '=' then return V.equals(a, b) end
  if op == '!=' then return not V.equals(a, b) end
  if op == '<' then return V.compare(a, b) < 0 end
  if op == '>' then return V.compare(a, b) > 0 end
  if op == '<=' then return V.compare(a, b) <= 0 end
  if op == '>=' then return V.compare(a, b) >= 0 end

  local ta, tb = V.typeof(a), V.typeof(b)
  if op == '+' then
    if ta == 'number' and tb == 'number' then return a + b end
    if (ta == 'string' or tb == 'string') and ta ~= 'null' and tb ~= 'null' and ta ~= 'array' and tb ~= 'array' then
      return M.tostring(a) .. M.tostring(b)
    end
    if both(a, b, 'date', 'duration') then return V.date_add(a, b, 1) end
    if both(a, b, 'duration', 'date') then return V.date_add(b, a, 1) end
    if both(a, b, 'duration', 'duration') then return V.duration_from_ms(V.duration_ms(a) + V.duration_ms(b)) end
    if ta == 'array' and tb == 'array' then
      local out = V.list({})
      vim.list_extend(out, a)
      vim.list_extend(out, b)
      return out
    end
    return NULL
  end
  if op == '-' then
    if ta == 'number' and tb == 'number' then return a - b end
    if both(a, b, 'date', 'duration') then return V.date_add(a, b, -1) end
    if both(a, b, 'date', 'date') then return V.duration_from_ms((a.ts - b.ts) * 1000) end
    if both(a, b, 'duration', 'duration') then return V.duration_from_ms(V.duration_ms(a) - V.duration_ms(b)) end
    return NULL
  end
  if op == '*' then
    if ta == 'number' and tb == 'number' then return a * b end
    if both(a, b, 'string', 'number') then return b >= 0 and a:rep(math.floor(b)) or NULL end
    if both(a, b, 'number', 'string') then return a >= 0 and b:rep(math.floor(a)) or NULL end
    if both(a, b, 'duration', 'number') then return V.duration_from_ms(V.duration_ms(a) * b) end
    if both(a, b, 'number', 'duration') then return V.duration_from_ms(V.duration_ms(b) * a) end
    return NULL
  end
  if op == '/' then
    if ta == 'number' and tb == 'number' then return a / b end
    if both(a, b, 'duration', 'number') then return V.duration_from_ms(V.duration_ms(a) / b) end
    if both(a, b, 'duration', 'duration') then return V.duration_ms(a) / V.duration_ms(b) end
    return NULL
  end
  if op == '%' then
    if ta == 'number' and tb == 'number' then return a % b end
    return NULL
  end
  return NULL
end

return M
