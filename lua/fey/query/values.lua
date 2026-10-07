-- Runtime values of the query language (the Dataview data model).
--
--   null      vim.NIL (nil is accepted wherever null is expected)
--   boolean, number, string
--   array     table with metatable V.LIST
--   object    table with metatable V.OBJECT (or a lazy page, see query/pages.lua)
--   date      { ts = epoch seconds, time = has a time component }
--   duration  { years, months, weeks, days, hours, minutes, seconds, milliseconds }
--   link      { path, display, subpath, embed, hollow }   `hollow`: id of the hollow the file is in (court:notes), when known
--   function  Lua function (lambdas)
local M = {}

local NULL = vim.NIL
M.NULL = NULL

M.LIST = { __name = 'list' }
M.OBJECT = { __name = 'object' }
M.DATE = { __name = 'date' }
M.DURATION = { __name = 'duration' }
M.LINK = { __name = 'link' }
M.PAGE = { __name = 'page' } -- lazy objects (pages, sections); behave like objects

---@param v any
function M.is_null(v) return v == nil or v == NULL end

---@param t? table
---@return table
function M.list(t) return setmetatable(t or {}, M.LIST) end

---@param t? table
---@return table
function M.object(t) return setmetatable(t or {}, M.OBJECT) end

---@param v any
function M.is_list(v) return type(v) == 'table' and getmetatable(v) == M.LIST end
---@param v any
function M.is_date(v) return type(v) == 'table' and getmetatable(v) == M.DATE end
---@param v any
function M.is_duration(v) return type(v) == 'table' and getmetatable(v) == M.DURATION end
---@param v any
function M.is_link(v) return type(v) == 'table' and getmetatable(v) == M.LINK end
---@param v any
function M.is_object(v)
  local mt = type(v) == 'table' and getmetatable(v)
  return mt == M.OBJECT or mt == M.PAGE
end

---@param v any
---@return string
function M.typeof(v)
  if M.is_null(v) then return 'null' end
  local t = type(v)
  if t == 'table' then
    local mt = getmetatable(v)
    if mt == M.LIST then return 'array' end
    if mt == M.DATE then return 'date' end
    if mt == M.DURATION then return 'duration' end
    if mt == M.LINK then return 'link' end
    return 'object'
  end
  if t == 'function' then return 'function' end
  return t
end

-- Dates and durations ---------------------------------------------------------

-- Luxon's "casual" conversion, which Dataview relies on
local MS = {
  milliseconds = 1,
  seconds = 1000,
  minutes = 60000,
  hours = 3600000,
  days = 86400000,
  weeks = 7 * 86400000,
  months = 30 * 86400000,
  years = 365 * 86400000,
}
local UNITS = { 'years', 'months', 'weeks', 'days', 'hours', 'minutes', 'seconds', 'milliseconds' }
M.DURATION_UNITS = UNITS

---@param ts number epoch seconds
---@param time? boolean
function M.date(ts, time) return setmetatable({ ts = ts, time = time or false }, M.DATE) end

---@param c table partial components
function M.duration(c)
  local d = {}
  for _, u in ipairs(UNITS) do
    d[u] = c[u] or 0
  end
  return setmetatable(d, M.DURATION)
end

---Total milliseconds (casual: month = 30 days, year = 365 days)
---@param d table
function M.duration_ms(d)
  local total = 0
  for _, u in ipairs(UNITS) do
    total = total + (d[u] or 0) * MS[u]
  end
  return total
end

---Normalise to the largest units (like Luxon's shiftTo of every unit)
---@param ms number
function M.duration_from_ms(ms)
  local out, rest = {}, math.abs(ms)
  local sign = ms < 0 and -1 or 1
  for _, u in ipairs(UNITS) do
    local n = math.floor(rest / MS[u])
    out[u] = n * sign
    rest = rest - n * MS[u]
  end
  return M.duration(out)
end

---@param d table duration
---@return string
function M.duration_tostring(d)
  local norm = M.duration_from_ms(M.duration_ms(d))
  local parts = {}
  for _, u in ipairs(UNITS) do
    local n = norm[u]
    if n ~= 0 then
      local name = math.abs(n) == 1 and u:sub(1, -2) or u
      table.insert(parts, ('%d %s'):format(n, name))
    end
  end
  if #parts == 0 then return '0 seconds' end
  return table.concat(parts, ', ')
end

---@param d table date
---@return osdateparam
function M.date_fields(d) return os.date('*t', math.floor(d.ts)) --[[@as osdateparam]] end

---@param y integer
---@param mo integer
---@param day integer
---@param h? integer
---@param mi? integer
---@param s? integer
---@return number
function M.make_ts(y, mo, day, h, mi, s)
  return os.time({ year = y, month = mo, day = day, hour = h or 0, min = mi or 0, sec = s or 0 })
end

---Add a duration to a date, calendar aware for years and months
---@param d table
---@param dur table
---@param sign? integer 1 or -1
function M.date_add(d, dur, sign)
  sign = sign or 1
  local f = M.date_fields(d)
  local ts = os.time({
    year = f.year + sign * (dur.years or 0),
    month = f.month + sign * (dur.months or 0),
    day = f.day,
    hour = f.hour,
    min = f.min,
    sec = f.sec,
  })
  local rest = (dur.weeks or 0) * MS.weeks
    + (dur.days or 0) * MS.days
    + (dur.hours or 0) * MS.hours
    + (dur.minutes or 0) * MS.minutes
    + (dur.seconds or 0) * MS.seconds
    + (dur.milliseconds or 0)
  return M.date(ts + sign * rest / 1000, d.time)
end

local unit_aliases = {
  ms = 'milliseconds', msec = 'milliseconds', msecs = 'milliseconds', millisecond = 'milliseconds', milliseconds = 'milliseconds',
  s = 'seconds', sec = 'seconds', secs = 'seconds', second = 'seconds', seconds = 'seconds',
  m = 'minutes', min = 'minutes', mins = 'minutes', minute = 'minutes', minutes = 'minutes',
  h = 'hours', hr = 'hours', hrs = 'hours', hour = 'hours', hours = 'hours',
  d = 'days', day = 'days', days = 'days',
  w = 'weeks', wk = 'weeks', wks = 'weeks', week = 'weeks', weeks = 'weeks',
  mo = 'months', mos = 'months', month = 'months', months = 'months',
  y = 'years', yr = 'years', yrs = 'years', year = 'years', years = 'years',
}

---Parse "1 day 2 hours", "1d2h", "3 months, 2 weeks"
---@param s string
---@return table|nil duration
function M.parse_duration(s)
  local c, found = {}, false
  local pos = 1
  s = s:lower()
  while pos <= #s do
    local a, b, num, unit = s:find('^[%s,]*(%-?%d+%.?%d*)%s*(%a+)', pos)
    if not a then
      if s:find('^[%s,]*$', pos) then break end
      return nil
    end
    local u = unit_aliases[unit]
    if not u then return nil end
    c[u] = (c[u] or 0) + tonumber(num)
    found = true
    pos = b + 1
  end
  return found and M.duration(c) or nil
end

---@param s string
---@return table|nil date
function M.parse_date(s)
  s = vim.trim(s)
  local y, mo, d, rest = s:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)(.*)$')
  if not y then
    y, mo = s:match('^(%d%d%d%d)%-(%d%d)$')
    if y then return M.date(M.make_ts(tonumber(y), tonumber(mo), 1)) end
    y = s:match('^(%d%d%d%d)$')
    if y then return M.date(M.make_ts(tonumber(y), 1, 1)) end
    y, mo, d = s:match('^(%d%d%d%d)(%d%d)(%d%d)$')
    if not y then return nil end
    rest = ''
  end
  y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
  if mo < 1 or mo > 12 or d < 1 or d > 31 then return nil end
  if rest == '' then return M.date(M.make_ts(y, mo, d)) end

  local h, mi, sec, frac, tail = rest:match('^[T ](%d%d):(%d%d):?(%d*)%.?(%d*)(.*)$')
  if not h then return nil end
  local ts = M.make_ts(y, mo, d, tonumber(h), tonumber(mi), tonumber(sec ~= '' and sec or 0))
  if frac ~= '' then ts = ts + tonumber('0.' .. frac) end
  if tail == 'Z' or tail:match('^[%+%-]%d%d:?%d%d$') then
    -- the wall clock above was read as local time: shift it to the given offset
    local off = 0
    if tail ~= 'Z' then
      local sign, oh, om = tail:match('^([%+%-])(%d%d):?(%d%d)$')
      off = (tonumber(oh) * 3600 + tonumber(om) * 60) * (sign == '-' and -1 or 1)
    end
    local local_off = os.time(os.date('*t', ts) --[[@as osdateparam]]) - os.time(os.date('!*t', ts) --[[@as osdateparam]])
    ts = ts + local_off - off
  elseif tail ~= '' then
    return nil
  end
  return M.date(ts, true)
end

-- Equality, ordering, truthiness ------------------------------------------------

local TYPE_RANK = {
  null = 0, boolean = 1, number = 2, string = 3, date = 4, duration = 5, link = 6, array = 7, object = 8, ['function'] = 9,
}

---@param v any
---@return number|string|boolean|nil
local function link_key(v)
  -- `[[notes/a]]` and `notes/a.fey` name the same page
  return (v.path:gsub('%.fey$', ''):gsub('%.fey_archive$', '')):lower() .. (v.subpath and ('#' .. v.subpath) or '')
end

---Total order across all values (negative, 0, positive)
---@param a any
---@param b any
---@return integer
function M.compare(a, b)
  local ta, tb = M.typeof(a), M.typeof(b)
  if ta ~= tb then return TYPE_RANK[ta] < TYPE_RANK[tb] and -1 or 1 end
  if ta == 'null' then return 0 end
  if ta == 'number' or ta == 'boolean' then
    local x, y = ta == 'boolean' and (a and 1 or 0) or a, ta == 'boolean' and (b and 1 or 0) or b
    return x < y and -1 or (x > y and 1 or 0)
  end
  if ta == 'string' then
    -- case-insensitive first, like localeCompare, then by bytes
    local la, lb = a:lower(), b:lower()
    if la ~= lb then return la < lb and -1 or 1 end
    return a < b and -1 or (a > b and 1 or 0)
  end
  if ta == 'date' then return a.ts < b.ts and -1 or (a.ts > b.ts and 1 or 0) end
  if ta == 'duration' then
    local x, y = M.duration_ms(a), M.duration_ms(b)
    return x < y and -1 or (x > y and 1 or 0)
  end
  if ta == 'link' then
    local x, y = link_key(a), link_key(b)
    if x ~= y then return x < y and -1 or 1 end
    -- the same path in two hollows is two files; a link that does not say which hollow matches either
    if a.hollow and b.hollow and a.hollow ~= b.hollow then return a.hollow < b.hollow and -1 or 1 end
    return 0
  end
  if ta == 'array' then
    for i = 1, math.min(#a, #b) do
      local c = M.compare(a[i], b[i])
      if c ~= 0 then return c end
    end
    return #a < #b and -1 or (#a > #b and 1 or 0)
  end
  if ta == 'object' then
    local ka, kb = M.keys(a), M.keys(b)
    for i = 1, math.min(#ka, #kb) do
      if ka[i] ~= kb[i] then return ka[i] < kb[i] and -1 or 1 end
      local c = M.compare(a[ka[i]], b[kb[i]])
      if c ~= 0 then return c end
    end
    return #ka < #kb and -1 or (#ka > #kb and 1 or 0)
  end
  return 0
end

---@param a any
---@param b any
function M.equals(a, b)
  if M.typeof(a) ~= M.typeof(b) then return false end
  return M.compare(a, b) == 0
end

---Sorted keys of an object
---@param o table
---@return string[]
function M.keys(o)
  local keys = {}
  local raw = rawget(o, '__keys')
  if raw then return raw() end
  for k in pairs(o) do
    if type(k) == 'string' and k:sub(1, 2) ~= '__' then table.insert(keys, k) end
  end
  table.sort(keys)
  return keys
end

---@param v any
function M.truthy(v)
  local t = M.typeof(v)
  if t == 'null' then return false end
  if t == 'boolean' then return v end
  if t == 'number' then return v ~= 0 end
  if t == 'string' then return v ~= '' end
  if t == 'array' then return #v > 0 end
  if t == 'link' then return v.path ~= '' end
  if t == 'object' then return #M.keys(v) > 0 end
  return true
end

---@param path string
---@param display? string
---@param subpath? string
---@param hollow? string id of the hollow the file is in
function M.link(path, display, subpath, hollow)
  return setmetatable({ path = path, display = display, subpath = subpath, embed = false, hollow = hollow }, M.LINK)
end

---Recursively convert decoded JSON into query values.
---With `dates`, strings that are ISO dates become dates (like Dataview does for fields).
---@param v any
---@param dates? boolean
function M.from_json(v, dates)
  if type(v) == 'string' then
    if dates and v:match('^%d%d%d%d%-%d%d%-%d%d') then return M.parse_date(v) or v end
    return v
  end
  if type(v) ~= 'table' then return v end
  if vim.islist(v) and next(v) ~= nil then
    local out = {}
    for i, item in ipairs(v) do
      out[i] = M.from_json(item, dates)
    end
    return M.list(out)
  end
  if next(v) == nil then
    -- an empty JSON array and object both decode to {}; only the object carries the dict metatable
    return getmetatable(v) == getmetatable(vim.empty_dict()) and M.object({}) or M.list({})
  end
  local out = {}
  for k, item in pairs(v) do
    out[k] = M.from_json(item, dates)
  end
  return M.object(out)
end

return M
