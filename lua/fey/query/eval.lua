-- Expression compiler: AST -> Lua closure, compiled once per query and run for every row.
local V = require('fey.query.values')
local ops = require('fey.query.ops')
local fns = require('fey.query.functions').functions

local NULL = V.NULL
local M = {}

---@class FeyQueryEnv
---@field row any current row (a page, section or derived row)
---@field scope table lambda parameters
---@field this any the page that holds the query
---@field resolve_link? fun(link: table): any

-- bare words `date(today)` accepts
local DATE_WORDS = {
  today = true, now = true, tomorrow = true, yesterday = true,
  sow = true, eow = true, som = true, eom = true, soy = true, eoy = true,
}

---@param ast table
---@return fun(env: FeyQueryEnv): any
local function compile(ast)
  local t = ast.t

  if t == 'num' or t == 'str' or t == 'bool' then
    local v = ast.v
    return function() return v end
  end
  if t == 'null' then return function() return NULL end end
  if t == 'date' then
    local d = V.parse_date(ast.v)
    return function() return d == nil and NULL or d end
  end

  if t == 'link' then
    local path, sub = ast.v:match('^(.-)#(.*)$')
    local target, display = (path or ast.v), nil
    local bar_target, bar_display = target:match('^(.-)|(.*)$')
    if bar_target then target, display = bar_target, bar_display end
    return function() return V.link(target, display, sub) end
  end

  if t == 'var' then
    local name = ast.name
    local lname = name:lower()
    return function(env)
      local v = env.scope[name]
      if v ~= nil then return v end
      if lname == 'this' then return env.this == nil and NULL or env.this end
      if lname == 'row' then return env.row == nil and NULL or env.row end
      local row = env.row
      if row ~= nil then
        v = ops.get(row, name)
        if v ~= NULL then return v end
      end
      return NULL
    end
  end

  if t == 'field' then
    local obj, name = compile(ast.obj), ast.name
    return function(env) return ops.get(obj(env), name) end
  end

  if t == 'index' then
    local obj, idx = compile(ast.obj), compile(ast.idx)
    return function(env) return ops.get(obj(env), idx(env)) end
  end

  if t == 'un' then
    local e = compile(ast.e)
    if ast.op == '!' then return function(env) return not V.truthy(e(env)) end end
    return function(env)
      local v = e(env)
      if type(v) == 'number' then return -v end
      if V.is_duration(v) then return V.duration_from_ms(-V.duration_ms(v)) end
      return NULL
    end
  end

  if t == 'bin' then
    local l, r, op = compile(ast.l), compile(ast.r), ast.op
    if op == 'and' then return function(env) return V.truthy(l(env)) and V.truthy(r(env)) end end
    if op == 'or' then return function(env) return V.truthy(l(env)) or V.truthy(r(env)) end end
    local binary = ops.binary
    return function(env) return binary(op, l(env), r(env)) end
  end

  if t == 'list' then
    local items = {}
    for i, item in ipairs(ast.items) do
      items[i] = compile(item)
    end
    return function(env)
      local out = {}
      for i, item in ipairs(items) do
        out[i] = item(env)
      end
      return V.list(out)
    end
  end

  if t == 'obj' then
    local keys, vals = {}, {}
    for i, p in ipairs(ast.pairs) do
      keys[i], vals[i] = p.k, compile(p.v)
    end
    return function(env)
      local out = V.object({})
      for i, k in ipairs(keys) do
        out[k] = vals[i](env)
      end
      return out
    end
  end

  if t == 'lambda' then
    local params, body = ast.params, compile(ast.body)
    return function(env)
      return function(...)
        local scope = setmetatable({}, { __index = env.scope })
        local args = { ... }
        for i, p in ipairs(params) do
          local a = args[i]
          scope[p] = a == nil and NULL or a
        end
        local v = body({ row = env.row, scope = scope, this = env.this })
        return v
      end
    end
  end

  if t == 'call' or t == 'mcall' then
    local fn = fns[ast.fn]
    local args = {}
    local first = 1
    if t == 'mcall' then
      args[1] = compile(ast.obj)
      first = 2
    end
    for i, a in ipairs(ast.args) do
      if ast.fn == 'date' and a.t == 'var' and DATE_WORDS[a.name:lower()] then
        local word = a.name:lower()
        args[first + i - 1] = function() return word end
      else
        args[first + i - 1] = compile(a)
      end
    end
    local name, n = ast.fn, #args
    if not fn then error(('query: unknown function %q'):format(name), 0) end
    return function(env)
      local vals = {}
      for i = 1, n do
        local v = args[i](env)
        vals[i] = v
      end
      local ok, res = pcall(fn, unpack(vals, 1, n))
      if not ok then
        if type(res) == 'string' and res:sub(1, 6) == 'query:' then error(res, 0) end
        return NULL -- like Dataview, a failing call yields null instead of aborting the query
      end
      if res == nil then return NULL end
      return res
    end
  end

  error('query: cannot compile ' .. tostring(t), 0)
end

M.compile = compile

---@param fn fun(env: FeyQueryEnv): any
---@param env FeyQueryEnv
function M.new_env(row, this) return { row = row, scope = {}, this = this } end

return M
