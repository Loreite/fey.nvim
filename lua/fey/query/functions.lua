-- The function library, named and behaving like Dataview's.
-- Every function takes already evaluated arguments. Lambdas arrive as Lua functions.
local V = require('fey.query.values')
local ops = require('fey.query.ops')

local NULL = V.NULL
local null = V.is_null

local F = {}
---@class FeyQueryFunctions
local M = { functions = F, clock = os.time }

---@param name string
---@param fn function
local function def(name, fn) F[name] = fn end

---Lift a one-value function over a list given as its first argument
---@param fn function
local function vectorize(fn)
  return function(a, ...)
    if V.is_list(a) then
      local out, rest = {}, { ... }
      for i, item in ipairs(a) do
        out[i] = fn(item, unpack(rest))
      end
      return V.list(out)
    end
    return fn(a, ...)
  end
end

local function def_vec(name, fn) def(name, vectorize(fn)) end

local function arr(v)
  if V.is_list(v) then return v end
  return V.list({ v })
end

-- Constructors -----------------------------------------------------------------

def('object', function(...)
  local args, o = { ... }, V.object({})
  for i = 1, #args - 1, 2 do
    if type(args[i]) == 'string' then o[args[i]] = args[i + 1] end
  end
  return o
end)

def('list', function(...) return V.list({ ... }) end)
def('array', F.list)

local function start_of(unit, d)
  local f = V.date_fields(d)
  if unit == 'week' then
    return V.make_ts(f.year, f.month, f.day - ((f.wday + 5) % 7))
  elseif unit == 'month' then
    return V.make_ts(f.year, f.month, 1)
  elseif unit == 'year' then
    return V.make_ts(f.year, 1, 1)
  end
  return V.make_ts(f.year, f.month, f.day)
end

local function keyword_date(word, now)
  local f = V.date_fields(V.date(now))
  if word == 'now' then return V.date(now, true) end
  if word == 'today' then return V.date(start_of('day', V.date(now))) end
  if word == 'tomorrow' then return V.date(V.make_ts(f.year, f.month, f.day + 1)) end
  if word == 'yesterday' then return V.date(V.make_ts(f.year, f.month, f.day - 1)) end
  if word == 'sow' then return V.date(start_of('week', V.date(now))) end
  if word == 'eow' then return V.date(V.make_ts(f.year, f.month, f.day - ((f.wday + 5) % 7) + 6)) end
  if word == 'som' then return V.date(start_of('month', V.date(now))) end
  if word == 'eom' then return V.date(V.make_ts(f.year, f.month + 1, 0)) end
  if word == 'soy' then return V.date(start_of('year', V.date(now))) end
  if word == 'eoy' then return V.date(V.make_ts(f.year, 12, 31)) end
  return nil
end

def('date', function(v)
  if V.is_date(v) then return v end
  if type(v) == 'string' then
    local now = M.clock()
    return keyword_date(v:lower(), now) or V.parse_date(v) or NULL
  end
  if V.is_link(v) then
    -- a daily note: the file name is the date
    local name = v.path:match('([^/]+)$') or v.path
    return V.parse_date((name:gsub('%.[^.]+$', ''))) or NULL
  end
  return NULL
end)

def('dur', function(v)
  if V.is_duration(v) then return v end
  if type(v) == 'string' then return V.parse_duration(v) or NULL end
  return NULL
end)
def('duration', F.dur)

def('number', function(v)
  if type(v) == 'number' then return v end
  if type(v) ~= 'string' then return NULL end
  local m = v:match('%-?%d+%.?%d*')
  return m and tonumber(m) or NULL
end)

def('string', function(v) return ops.tostring(v) end)

def('link', function(path, display)
  if V.is_link(path) then
    return V.link(path.path, display or path.display, path.subpath)
  end
  if type(path) ~= 'string' then return NULL end
  local p, sub = path:match('^(.-)#(.*)$')
  return V.link(p or path, display, sub)
end)

def('embed', function(path, display)
  local l = F.link(path, display)
  if V.is_link(l) then l.embed = true end
  return l
end)

def('elink', function(url, display)
  if type(url) ~= 'string' then return NULL end
  return V.link(url, display)
end)

def('typeof', V.typeof)

def('choice', function(cond, a, b)
  if V.truthy(cond) then return a end
  return b == nil and NULL or b
end)

def('default', function(v, fallback)
  if null(v) then return fallback == nil and NULL or fallback end
  return v
end)

def('ldefault', function(v, fallback)
  if V.is_list(v) then
    local out = {}
    for i, item in ipairs(v) do
      out[i] = null(item) and fallback or item
    end
    return V.list(out)
  end
  return null(v) and fallback or v
end)

def('striptime', function(d)
  if not V.is_date(d) then return NULL end
  return V.date(start_of('day', d))
end)

def('localtime', function(d) return d end)

def('meta', function(l)
  if not V.is_link(l) then return NULL end
  return V.object({ path = l.path, subpath = l.subpath or NULL, display = l.display or NULL, embed = l.embed })
end)

-- Numbers ----------------------------------------------------------------------

def_vec('round', function(n, digits)
  if type(n) ~= 'number' then return NULL end
  local m = 10 ^ (digits or 0)
  return math.floor(n * m + 0.5) / m
end)
def_vec('trunc', function(n) return type(n) == 'number' and (n >= 0 and math.floor(n) or math.ceil(n)) or NULL end)
def_vec('floor', function(n) return type(n) == 'number' and math.floor(n) or NULL end)
def_vec('ceil', function(n) return type(n) == 'number' and math.ceil(n) or NULL end)

local function flatten_args(...)
  local args = { ... }
  if #args == 1 and V.is_list(args[1]) then return args[1] end
  return args
end

def('min', function(...)
  local best
  for _, v in ipairs(flatten_args(...)) do
    if not null(v) and (best == nil or V.compare(v, best) < 0) then best = v end
  end
  return best == nil and NULL or best
end)
def('max', function(...)
  local best
  for _, v in ipairs(flatten_args(...)) do
    if not null(v) and (best == nil or V.compare(v, best) > 0) then best = v end
  end
  return best == nil and NULL or best
end)

def('sum', function(list)
  local acc
  for _, v in ipairs(arr(list)) do
    if not null(v) then acc = acc == nil and v or ops.binary('+', acc, v) end
  end
  return acc == nil and 0 or acc
end)

def('product', function(list)
  local acc = 1
  for _, v in ipairs(arr(list)) do
    if type(v) == 'number' then acc = acc * v end
  end
  return acc
end)

def('average', function(list)
  local l = arr(list)
  local n, total = 0, 0
  for _, v in ipairs(l) do
    if type(v) == 'number' then
      n, total = n + 1, total + v
    end
  end
  return n == 0 and NULL or total / n
end)

def('minby', function(list, fn)
  local best, best_key
  for _, v in ipairs(arr(list)) do
    local k = fn(v)
    if best_key == nil or V.compare(k, best_key) < 0 then best, best_key = v, k end
  end
  return best == nil and NULL or best
end)
def('maxby', function(list, fn)
  local best, best_key
  for _, v in ipairs(arr(list)) do
    local k = fn(v)
    if best_key == nil or V.compare(k, best_key) > 0 then best, best_key = v, k end
  end
  return best == nil and NULL or best
end)

def('reduce', function(list, op)
  local l = arr(list)
  if #l == 0 then return NULL end
  local acc = l[1]
  for i = 2, #l do
    if type(op) == 'function' then
      acc = op(acc, l[i])
    else
      acc = ops.binary(op, acc, l[i])
    end
  end
  return acc
end)

-- Arrays and objects -----------------------------------------------------------

def('length', function(v)
  if V.is_list(v) or type(v) == 'string' then return #v end
  if V.is_object(v) then return #V.keys(v) end
  return 0
end)

def('nonnull', function(list)
  local out = {}
  for _, v in ipairs(arr(list)) do
    if not null(v) then out[#out + 1] = v end
  end
  return V.list(out)
end)

---@param list table
---@param fn? fun(v: any): any
---@return boolean[]
local function each_truthy(list, fn)
  local out = {}
  for i, v in ipairs(arr(list)) do
    out[i] = V.truthy(fn and fn(v) or (not fn and v))
  end
  return out
end

def('all', function(list, fn)
  for _, t in ipairs(each_truthy(list, fn)) do
    if not t then return false end
  end
  return true
end)
def('any', function(list, fn)
  for _, t in ipairs(each_truthy(list, fn)) do
    if t then return true end
  end
  return false
end)
def('none', function(list, fn)
  for _, t in ipairs(each_truthy(list, fn)) do
    if t then return false end
  end
  return true
end)

def('filter', function(list, fn)
  local out = {}
  for _, v in ipairs(arr(list)) do
    if V.truthy(fn(v)) then out[#out + 1] = v end
  end
  return V.list(out)
end)

def('map', function(list, fn)
  local out = {}
  for i, v in ipairs(arr(list)) do
    local r = fn(v, i - 1)
    out[i] = r == nil and NULL or r
  end
  return V.list(out)
end)

local function flat(list, depth, out)
  for _, v in ipairs(list) do
    if V.is_list(v) and depth > 0 then flat(v, depth - 1, out) else out[#out + 1] = v end
  end
  return out
end
def('flat', function(list, depth) return V.list(flat(arr(list), depth or 1, {})) end)

def('slice', function(list, from, to)
  local l = arr(list)
  from = from or 0
  to = to or #l
  if from < 0 then from = math.max(#l + from, 0) end
  if to < 0 then to = math.max(#l + to, 0) end
  local out = {}
  for i = from + 1, math.min(to, #l) do
    out[#out + 1] = l[i]
  end
  return V.list(out)
end)

def('reverse', function(list)
  local l, out = arr(list), {}
  for i = #l, 1, -1 do
    out[#out + 1] = l[i]
  end
  return V.list(out)
end)

def('unique', function(list)
  local out = {}
  for _, v in ipairs(arr(list)) do
    local seen = false
    for _, o in ipairs(out) do
      if V.equals(o, v) then
        seen = true
        break
      end
    end
    if not seen then out[#out + 1] = v end
  end
  return V.list(out)
end)

def('sort', function(list, key, dir)
  local l = arr(list)
  local desc = type(key) == 'string' and key:lower():match('^desc') or type(dir) == 'string' and dir:lower():match('^desc')
  local keyfn = type(key) == 'function' and key or nil
  local decorated = {}
  for i, v in ipairs(l) do
    decorated[i] = { v = v, k = keyfn and keyfn(v) or v, i = i }
  end
  table.sort(decorated, function(a, b)
    local c = V.compare(a.k, b.k)
    if c == 0 then return a.i < b.i end
    if desc then return c > 0 end
    return c < 0
  end)
  local out = {}
  for i, d in ipairs(decorated) do
    out[i] = d.v
  end
  return V.list(out)
end)

def('join', function(list, delim)
  local parts = {}
  for i, v in ipairs(arr(list)) do
    parts[i] = ops.tostring(v)
  end
  return table.concat(parts, delim or ', ')
end)

def('firstvalue', function(...)
  for _, v in ipairs(flatten_args(...)) do
    if not null(v) then return v end
  end
  return NULL
end)

def('extract', function(obj, ...)
  local out = V.object({})
  for _, k in ipairs({ ... }) do
    out[k] = ops.get(obj, k)
  end
  return out
end)

local function contains_impl(fold, exact)
  return function(container, value)
    local function norm(s) return fold and type(s) == 'string' and s:lower() or s end
    if type(container) == 'string' then
      if type(value) ~= 'string' then return false end
      return container ~= nil and norm(container):find(norm(value), 1, true) ~= nil
    end
    if V.is_list(container) then
      for _, item in ipairs(container) do
        if exact or type(item) ~= 'string' then
          if V.equals(item, value) or (fold and norm(item) == norm(value)) then return true end
        elseif type(value) == 'string' and norm(item):find(norm(value), 1, true) then
          return true
        end
      end
      return false
    end
    if V.is_object(container) then
      if type(value) ~= 'string' then return false end
      for _, k in ipairs(V.keys(container)) do
        if norm(k) == norm(value) then return true end
      end
      return false
    end
    return false
  end
end
def('contains', contains_impl(false, false))
def('icontains', contains_impl(true, false))
def('econtains', contains_impl(false, true))

-- Strings ----------------------------------------------------------------------

local regex_cache = {}

---Translate the common JS regex syntax to Vim's very magic regex
---@param pat string
---@param opts? { anchored?: boolean }
local function compile_regex(pat, opts)
  opts = opts or {}
  local key = pat .. (opts.anchored and '\0a' or '')
  if regex_cache[key] then return regex_cache[key] end
  local flags = ''
  if pat:sub(1, 4) == '(?i)' then
    flags, pat = '\\c', pat:sub(5)
  end
  pat = pat:gsub('%(%?:', '%%('):gsub('%*%?', '{-}'):gsub('%+%?', '{-1,}'):gsub('\\b', '%%(<|>)')
  if opts.anchored then pat = '^%(' .. pat .. ')$' end
  local ok, re = pcall(vim.regex, '\\v' .. flags .. pat)
  regex_cache[key] = ok and re or false
  return regex_cache[key]
end

def('regextest', function(pat, s)
  if type(pat) ~= 'string' or type(s) ~= 'string' then return false end
  local re = compile_regex(pat)
  return re and re:match_str(s) ~= nil or false
end)

def('regexmatch', function(pat, s)
  if type(pat) ~= 'string' or type(s) ~= 'string' then return false end
  local re = compile_regex(pat, { anchored = true })
  return re and re:match_str(s) ~= nil or false
end)

def_vec('regexreplace', function(s, pat, repl)
  if type(s) ~= 'string' or type(pat) ~= 'string' or type(repl) ~= 'string' then return NULL end
  if not compile_regex(pat) then return NULL end
  local flags = pat:sub(1, 4) == '(?i)' and '\\c' or ''
  local body = pat:sub(1, 4) == '(?i)' and pat:sub(5) or pat
  -- JS `$1` -> Vim `\1`; keep literal backslashes and ampersands
  local r = repl:gsub('\\', '\\\\'):gsub('&', '\\&'):gsub('%$(%d)', '\\%1')
  local ok, out = pcall(vim.fn.substitute, s, '\\v' .. flags .. body, r, 'g')
  return ok and out or NULL
end)

def_vec('replace', function(s, pat, repl)
  if type(s) ~= 'string' or type(pat) ~= 'string' or type(repl) ~= 'string' then return NULL end
  if pat == '' then return s end
  return (s:gsub(vim.pesc(pat), (repl:gsub('%%', '%%%%'))))
end)

def_vec('lower', function(s) return type(s) == 'string' and s:lower() or NULL end)
def_vec('upper', function(s) return type(s) == 'string' and s:upper() or NULL end)

def('split', function(s, delim, limit)
  if type(s) ~= 'string' or type(delim) ~= 'string' then return NULL end
  local re = compile_regex(delim)
  local out, pos = {}, 1
  while re and (not limit or #out < limit - 1) do
    local a, b = re:match_str(s:sub(pos))
    if not a or b == a then break end
    out[#out + 1] = s:sub(pos, pos + a - 1)
    pos = pos + b
  end
  out[#out + 1] = s:sub(pos)
  return V.list(out)
end)

def_vec('startswith', function(s, p) return type(s) == 'string' and type(p) == 'string' and s:sub(1, #p) == p end)
def_vec('endswith', function(s, p) return type(s) == 'string' and type(p) == 'string' and (p == '' or s:sub(-#p) == p) end)

local function pad(s, len, ch, left)
  if type(s) ~= 'string' or type(len) ~= 'number' then return NULL end
  ch = (type(ch) == 'string' and ch ~= '') and ch or ' '
  local need = len - vim.fn.strchars(s)
  if need <= 0 then return s end
  local fill = ch:rep(math.ceil(need / vim.fn.strchars(ch)))
  fill = vim.fn.strcharpart(fill, 0, need)
  return left and fill .. s or s .. fill
end
def_vec('padleft', function(s, len, ch) return pad(s, len, ch, true) end)
def_vec('padright', function(s, len, ch) return pad(s, len, ch, false) end)

def_vec('substring', function(s, from, to)
  if type(s) ~= 'string' or type(from) ~= 'number' then return NULL end
  local n = vim.fn.strchars(s)
  to = to or n
  return vim.fn.strcharpart(s, math.max(from, 0), math.max(math.min(to, n) - math.max(from, 0), 0))
end)

def_vec('truncate', function(s, len, suffix)
  if type(s) ~= 'string' or type(len) ~= 'number' then return NULL end
  suffix = type(suffix) == 'string' and suffix or '...'
  if vim.fn.strchars(s) <= len then return s end
  return vim.fn.strcharpart(s, 0, math.max(len - vim.fn.strchars(suffix), 0)) .. suffix
end)

def('containsword', function(v, word)
  if type(word) ~= 'string' then return false end
  local re = compile_regex('(?i)\\b' .. vim.pesc(word):gsub('%%', '\\') .. '\\b')
  local function test(s) return type(s) == 'string' and re and re:match_str(s) ~= nil or false end
  if V.is_list(v) then
    for _, item in ipairs(v) do
      if test(item) then return true end
    end
    return false
  end
  return test(v)
end)

-- Dates ------------------------------------------------------------------------

local TOKEN_ORDER = {
  'yyyy', 'yy', 'MMMM', 'MMM', 'MM', 'M', 'dd', 'd', 'cccc', 'ccc', 'EEEE', 'EEE', 'HH', 'H', 'hh', 'h', 'mm', 'm',
  'ss', 's', 'SSS', 'a', 'x', 'X',
}

---Luxon style format tokens (subset): yyyy MM dd HH mm ss MMMM MMM cccc ccc a ...
---@param d table date
---@param fmt string
local function format_date(d, fmt)
  local f = V.date_fields(d)
  local h12 = f.hour % 12 == 0 and 12 or f.hour % 12
  local tokens = {
    yyyy = ('%04d'):format(f.year),
    yy = ('%02d'):format(f.year % 100),
    MMMM = ops.MONTHS[f.month],
    MMM = ops.MONTHS[f.month]:sub(1, 3),
    MM = ('%02d'):format(f.month),
    M = tostring(f.month),
    dd = ('%02d'):format(f.day),
    d = tostring(f.day),
    cccc = ops.WEEKDAYS[f.wday],
    ccc = ops.WEEKDAYS[f.wday]:sub(1, 3),
    EEEE = ops.WEEKDAYS[f.wday],
    EEE = ops.WEEKDAYS[f.wday]:sub(1, 3),
    HH = ('%02d'):format(f.hour),
    H = tostring(f.hour),
    hh = ('%02d'):format(h12),
    h = tostring(h12),
    mm = ('%02d'):format(f.min),
    m = tostring(f.min),
    ss = ('%02d'):format(f.sec),
    s = tostring(f.sec),
    SSS = ('%03d'):format(math.floor((d.ts % 1) * 1000 + 0.5)),
    a = f.hour < 12 and 'AM' or 'PM',
    x = ('%d'):format(d.ts * 1000),
    X = ('%d'):format(d.ts),
  }
  local out, i = {}, 1
  while i <= #fmt do
    local c = fmt:sub(i, i)
    if c == "'" then
      local close = fmt:find("'", i + 1, true) or #fmt + 1
      out[#out + 1] = fmt:sub(i + 1, close - 1)
      i = close + 1
    else
      local matched
      for _, tok in ipairs(TOKEN_ORDER) do
        if fmt:sub(i, i + #tok - 1) == tok then
          matched = tok
          break
        end
      end
      if matched then
        out[#out + 1] = tokens[matched]
        i = i + #matched
      else
        out[#out + 1] = c
        i = i + 1
      end
    end
  end
  return table.concat(out)
end

def('dateformat', function(d, fmt)
  if V.is_link(d) then d = F.date(d) end
  if not V.is_date(d) or type(fmt) ~= 'string' then return NULL end
  return format_date(d, fmt)
end)

def('durationformat', function(dur, fmt)
  if not V.is_duration(dur) or type(fmt) ~= 'string' then return NULL end
  local n = V.duration_from_ms(V.duration_ms(dur))
  local map = {
    y = 'years', M = 'months', w = 'weeks', d = 'days', h = 'hours', m = 'minutes', s = 'seconds', S = 'milliseconds',
  }
  return (fmt:gsub("(%a)(%a*)", function(c, rest)
    local unit = map[c]
    if unit and rest == c:rep(#rest) then return ('%0' .. (#rest + 1) .. 'd'):format(math.floor(math.abs(n[unit]))) end
    return nil
  end))
end)

-- Bases style helpers (also reachable as methods: `file.hasTag("x")`) ----------------

local function label_match(labels, wanted)
  wanted = wanted:gsub('^#', ''):lower()
  for _, l in ipairs(labels) do
    local lower = l:lower()
    if lower == wanted or lower:sub(1, #wanted + 1) == wanted .. '/' then return true end
  end
  return false
end

def('hastag', function(file, ...)
  local labels = ops.get(file, 'labels')
  if not V.is_list(labels) then return false end
  for _, want in ipairs({ ... }) do
    if type(want) == 'string' and label_match(labels, want) then return true end
  end
  return false
end)
def('haslabel', F.hastag)

def('infolder', function(file, folder)
  local path = ops.get(file, 'path')
  if type(path) ~= 'string' or type(folder) ~= 'string' then return false end
  folder = folder:gsub('/+$', '')
  return path:sub(1, #folder + 1) == folder .. '/'
end)

def('haslink', function(file, link)
  local outs = ops.get(file, 'outlinks')
  if not V.is_list(outs) then return false end
  if type(link) == 'string' then link = V.link(link) end
  for _, o in ipairs(outs) do
    if V.equals(o, link) then return true end
  end
  return false
end)

def('isempty', function(v)
  if null(v) then return true end
  if type(v) == 'string' then return v == '' end
  if V.is_list(v) then return #v == 0 end
  if V.is_object(v) then return #V.keys(v) == 0 end
  return false
end)

def('today', function() return F.date('today') end)
def('now', function() return F.date('now') end)

M.format_date = format_date

return M
