-- Query pipeline: parse -> resolve FROM against the vault index -> run the
-- commands in order -> project rows into a TABLE or LIST result.
local V = require('fey.query.values')
local ops = require('fey.query.ops')
local parser = require('fey.query.parser')
local eval = require('fey.query.eval')
local pages = require('fey.query.pages')

local NULL = V.NULL
local M = {}

-- Compiling is the same for every run of the same text, keep the last few
---@type table<string, table>
local compiled_cache, compiled_order = {}, {}
local CACHE_SIZE = 64

---@class FeyQueryResult
---@field type 'table'|'list'
---@field headers? string[] table column titles
---@field rows? any[][] table rows (query values)
---@field items? table[] list items: { id?: any, value?: any, task?: any, children?: table[] }
---@field count integer number of result rows
---@field grouped boolean

---@param ast table
---@return table
local function compile_query(ast)
  local c = { fields = {}, commands = {} }
  for i, f in ipairs(ast.fields) do
    c.fields[i] = { fn = eval.compile(f.expr), alias = f.alias, text = f.text }
  end
  for i, cmd in ipairs(ast.commands) do
    local out = { op = cmd.op, source = cmd.source, alias = cmd.alias, text = cmd.text }
    if cmd.expr then out.fn = eval.compile(cmd.expr) end
    if cmd.keys then
      out.keys = {}
      for j, k in ipairs(cmd.keys) do
        out.keys[j] = { fn = eval.compile(k.expr), desc = k.desc }
      end
    end
    c.commands[i] = out
  end
  return c
end

---@param src string
local function get_compiled(src)
  local hit = compiled_cache[src]
  if hit then return hit end
  local ast = parser.parse(src)
  local compiled = { ast = ast, c = compile_query(ast) }
  compiled_cache[src] = compiled
  table.insert(compiled_order, src)
  if #compiled_order > CACHE_SIZE then compiled_cache[table.remove(compiled_order, 1)] = nil end
  return compiled
end

---@param fn function
---@param row any
---@param this any
local function run_expr(fn, row, this) return fn(eval.new_env(row, this)) end

---Stable sort of rows by already computed keys
---@param rows any[]
---@param keys any[][] per row, one value per sort key
---@param desc boolean[]
local function stable_sort(rows, keys, desc)
  local idx = {}
  for i = 1, #rows do
    idx[i] = i
  end
  table.sort(idx, function(a, b)
    for k = 1, #desc do
      local c = V.compare(keys[a][k], keys[b][k])
      if c ~= 0 then
        if desc[k] then return c > 0 end
        return c < 0
      end
    end
    return a < b
  end)
  local out = {}
  for i, j in ipairs(idx) do
    out[i] = rows[j]
  end
  return out
end

---How many rows the leading WHEREs at `i` need to produce, when only a LIMIT follows them.
---Lets `WHERE ... LIMIT 10` stop scanning after ten matches.
---@param commands table[]
---@param i integer
---@param this any
---@return integer|nil
local function limit_hint(commands, i, this)
  for j = i + 1, #commands do
    local op = commands[j].op
    if op == 'limit' then
      local n = commands[j].fn(eval.new_env(nil, this))
      return type(n) == 'number' and math.max(math.floor(n), 0) or nil
    end
    if op ~= 'where' then return nil end
  end
  return nil
end

---@param row any
---@param this any
---@param file_link fun(row: any): any
local function id_value(row)
  local file = ops.get(row, 'file')
  local link = V.is_object(file) and ops.get(file, 'link') or NULL
  if V.is_link(link) and V.is_object(row) and ops.get(row, 'signature') ~= NULL then
    -- a section: link to the heading
    return V.link(link.path, ops.get(row, 'title'), ops.get(row, 'signature'))
  end
  return link
end

---@class FeyQueryRunOpts
---@field this? any page of the file the query lives in
---@field scope? FeyScopeSpec which hollows the query reads: `current` (the default), `tree`, `court` or a list of hollow references

---Run query text against a vault
---@param vault FeyVault
---@param src string
---@param opts? FeyQueryRunOpts
---@return FeyQueryResult
function M.run(vault, src, opts)
  opts = opts or {}
  local compiled = get_compiled(src)
  local ast, c = compiled.ast, compiled.c
  if ast.type == 'calendar' then error('query: CALENDAR queries need a calendar view and are not supported', 0) end

  local store = pages.scope_store(vault, opts.scope)
  local this = opts.this
  local function eval_in_source(node) return eval.compile(node)(eval.new_env(nil, this)) end

  -- FROM: only valid first, like in Dataview
  local source = { kind = 'page' }
  local start = 1
  for i, cmd in ipairs(c.commands) do
    if cmd.op == 'from' then
      if i ~= 1 then error('query: FROM must come directly after the query type', 0) end
      source = store:source(cmd.source, eval_in_source)
      start = 2
    end
  end

  local rows = {}
  for _, page in ipairs(store:pages()) do
    if store:accepts(source, page) then rows[#rows + 1] = page end
  end
  if source.kind == 'section' then rows = store:sections_of(rows) end
  -- TASK: the rows are the tasks (headings with a todo keyword or a priority) of those pages
  if ast.type == 'task' then rows = store:tasks_of(rows) end

  local grouped = false
  for i = start, #c.commands do
    local cmd = c.commands[i]

    if cmd.op == 'where' then
      local hint = limit_hint(c.commands, i, this)
      local out = {}
      for _, row in ipairs(rows) do
        if V.truthy(run_expr(cmd.fn, row, this)) then
          out[#out + 1] = row
          if hint and #out >= hint then break end
        end
      end
      rows = out

    elseif cmd.op == 'sort' then
      local keys, desc = {}, {}
      for k, key in ipairs(cmd.keys) do
        desc[k] = key.desc
      end
      for r, row in ipairs(rows) do
        local kv = {}
        for k, key in ipairs(cmd.keys) do
          kv[k] = run_expr(key.fn, row, this)
        end
        keys[r] = kv
      end
      rows = stable_sort(rows, keys, desc)

    elseif cmd.op == 'group' then
      local groups, order = {}, {}
      for _, row in ipairs(rows) do
        local key = run_expr(cmd.fn, row, this)
        local found
        for _, g in ipairs(order) do
          if V.equals(g.key, key) then
            found = g
            break
          end
        end
        if not found then
          found = { key = key, rows = {} }
          order[#order + 1] = found
        end
        table.insert(found.rows, row)
      end
      table.sort(order, function(a, b) return V.compare(a.key, b.key) < 0 end)
      rows = {}
      for _, g in ipairs(order) do
        local fields = { key = g.key, rows = V.list(g.rows) }
        if cmd.alias then fields[cmd.alias] = g.key end
        rows[#rows + 1] = pages.derive(nil, fields, { 'key', 'rows', cmd.alias })
      end
      grouped = true

    elseif cmd.op == 'flatten' then
      local name = cmd.alias or cmd.text
      local out = {}
      for _, row in ipairs(rows) do
        local v = run_expr(cmd.fn, row, this)
        if V.is_list(v) then
          for _, item in ipairs(v) do
            out[#out + 1] = pages.derive(row, { [name] = item }, { name })
          end
        else
          out[#out + 1] = pages.derive(row, { [name] = v }, { name })
        end
      end
      rows = out
      grouped = false

    elseif cmd.op == 'limit' then
      local n = run_expr(cmd.fn, nil, this)
      if type(n) ~= 'number' then error('query: LIMIT needs a number', 0) end
      n = math.max(math.floor(n), 0)
      if #rows > n then
        local out = {}
        for i2 = 1, n do
          out[i2] = rows[i2]
        end
        rows = out
      end

    elseif cmd.op == 'from' then
      error('query: FROM must come directly after the query type', 0)
    end
  end

  -- Projection
  local result = { type = ast.type, count = #rows, grouped = grouped }

  if ast.type == 'table' then
    local headers = {}
    if not ast.without_id then headers[1] = grouped and 'Group' or (source.kind == 'section' and 'Section' or 'File') end
    for _, f in ipairs(c.fields) do
      headers[#headers + 1] = f.alias or f.text
    end
    result.headers = headers
    result.rows = {}
    for _, row in ipairs(rows) do
      local cells = {}
      if not ast.without_id then cells[1] = grouped and ops.get(row, 'key') or id_value(row) end
      for _, f in ipairs(c.fields) do
        cells[#cells + 1] = run_expr(f.fn, row, this)
      end
      result.rows[#result.rows + 1] = cells
    end
    return result
  end

  -- TASK: every row is a task, or a group of them
  if ast.type == 'task' then
    result.items = {}
    for _, row in ipairs(rows) do
      if grouped then
        local item = { id = ops.get(row, 'key'), children = {} }
        for _, member in ipairs(ops.get(row, 'rows')) do
          item.children[#item.children + 1] = { task = member }
        end
        result.items[#result.items + 1] = item
      else
        result.items[#result.items + 1] = { task = row }
      end
    end
    return result
  end

  -- LIST
  result.items = {}
  local field = c.fields[1]
  for _, row in ipairs(rows) do
    local item = {}
    if grouped then
      item.id = ops.get(row, 'key')
      if field then
        item.value = run_expr(field.fn, row, this)
      else
        -- no expression: the group's pages underneath the key
        item.children = {}
        for _, member in ipairs(ops.get(row, 'rows')) do
          item.children[#item.children + 1] = { id = id_value(member) }
        end
      end
    else
      if not ast.without_id then item.id = id_value(row) end
      if field then item.value = run_expr(field.fn, row, this) end
      if ast.without_id and not field then item.id = id_value(row) end
    end
    result.items[#result.items + 1] = item
  end
  return result
end

return M
