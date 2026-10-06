-- Filters of a database view: a tree of groups and conditions that compiles to a
-- query-language expression.
--
--   { kind = 'group', mode = 'and'|'or'|'not', items = { ... } }
--   { kind = 'cond', prop = 'rating', op = 'gt', value = '3' }
--   { kind = 'expr', expr = 'contains(file.labels, "x")' }
--
-- `and` = all of, `or` = any of, `not` = none of (like Obsidian Bases).
local extract = require('fey.vault.extract')
local parser = require('fey.query.parser')
local eval = require('fey.query.eval')

local M = {}

---@class FeyDbOp
---@field id string
---@field label string
---@field arity 0|1 whether the operator takes a value
---@field group string loose grouping used to order the picker

---@type FeyDbOp[]
M.OPS = {
  { id = 'exists', label = 'exists', arity = 0, group = 'presence' },
  { id = 'missing', label = 'does not exist', arity = 0, group = 'presence' },
  { id = 'notempty', label = 'is not empty', arity = 0, group = 'presence' },
  { id = 'empty', label = 'is empty', arity = 0, group = 'presence' },
  { id = 'eq', label = 'is (=)', arity = 1, group = 'compare' },
  { id = 'ne', label = 'is not (!=)', arity = 1, group = 'compare' },
  { id = 'gt', label = 'greater than (>)', arity = 1, group = 'compare' },
  { id = 'ge', label = 'at least (>=)', arity = 1, group = 'compare' },
  { id = 'lt', label = 'less than (<)', arity = 1, group = 'compare' },
  { id = 'le', label = 'at most (<=)', arity = 1, group = 'compare' },
  { id = 'contains', label = 'contains', arity = 1, group = 'text' },
  { id = 'notcontains', label = 'does not contain', arity = 1, group = 'text' },
  { id = 'startswith', label = 'starts with', arity = 1, group = 'text' },
  { id = 'endswith', label = 'ends with', arity = 1, group = 'text' },
  { id = 'regex', label = 'matches regex', arity = 1, group = 'text' },
  { id = 'len_eq', label = 'length is', arity = 1, group = 'length' },
  { id = 'len_ne', label = 'length is not', arity = 1, group = 'length' },
  { id = 'len_gt', label = 'length greater than', arity = 1, group = 'length' },
  { id = 'len_ge', label = 'length at least', arity = 1, group = 'length' },
  { id = 'len_lt', label = 'length less than', arity = 1, group = 'length' },
  { id = 'len_le', label = 'length at most', arity = 1, group = 'length' },
  { id = 'is_true', label = 'is true', arity = 0, group = 'boolean' },
  { id = 'is_false', label = 'is false', arity = 0, group = 'boolean' },
  { id = 'before', label = 'is before (date)', arity = 1, group = 'date' },
  { id = 'after', label = 'is after (date)', arity = 1, group = 'date' },
  { id = 'haslabel', label = 'file has label', arity = 1, group = 'file' },
  { id = 'infolder', label = 'file is in folder', arity = 1, group = 'file' },
  { id = 'linksto', label = 'file links to', arity = 1, group = 'file' },
  { id = 'expr', label = 'custom expression', arity = 1, group = 'custom' },
}

---@type table<string, FeyDbOp>
M.OP_BY_ID = {}
for _, op in ipairs(M.OPS) do
  M.OP_BY_ID[op.id] = op
end

local RESERVED = {
  ['and'] = true, ['or'] = true, ['not'] = true, ['true'] = true, ['false'] = true, ['null'] = true,
  this = true, row = true, from = true, where = true, sort = true, group = true, flatten = true, limit = true, as = true,
}

---DQL expression that reads a property
---@param prop string `file.name`, `formula.x` or the name of a note property
---@return string
function M.prop_expr(prop)
  if prop:match('^file%.[%a_][%w_]*$') or prop:match('^formula%.[%a_][%w_]*$') then return prop end
  if prop:match('^[%a_][%w_%-]*$') and not RESERVED[prop:lower()] then return prop end
  return ('row["%s"]'):format((prop:gsub('\\', '\\\\'):gsub('"', '\\"')))
end

---@param s string
local function quote(s) return '"' .. s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n') .. '"' end

---Literal for text typed into a filter: numbers, booleans and ISO dates stay typed
---@param text string
---@param ptype? string property type, when known
---@return string
function M.literal(text, ptype)
  text = vim.trim(text)
  if ptype ~= 'string' then
    local v = extract.scalar(text)
    if type(v) == 'number' then return tostring(v) end
    if type(v) == 'boolean' then return tostring(v) end
    if v ~= text then return quote(v) end -- explicitly quoted
  end
  if text:match('^%d%d%d%d%-%d%d%-%d%d$') or text:match('^%d%d%d%d%-%d%d%-%d%dT[%d:%.]+Z?$') then return text end
  local unquoted = text:match('^"(.*)"$') or text:match("^'(.*)'$") or text
  return quote(unquoted)
end

local COMPARE = { eq = '=', ne = '!=', gt = '>', ge = '>=', lt = '<', le = '<=', before = '<', after = '>' }
local LENGTH = { len_eq = '=', len_ne = '!=', len_gt = '>', len_ge = '>=', len_lt = '<', len_le = '<=' }

---Expression of one condition
---@param cond table
---@param types? table<string, string> property types
---@return string
function M.build_cond(cond, types)
  if cond.kind == 'expr' then return cond.expr or 'true' end
  local op = cond.op
  local P = M.prop_expr(cond.prop or 'file.name')
  local ptype = types and types[cond.prop]
  local value = cond.value or ''
  local L = M.literal(value, ptype)

  if op == 'exists' then return P .. ' != null' end
  if op == 'missing' then return P .. ' = null' end
  if op == 'empty' then return ('isempty(%s)'):format(P) end
  if op == 'notempty' then return ('!isempty(%s)'):format(P) end
  if op == 'is_true' then return P .. ' = true' end
  if op == 'is_false' then return P .. ' = false' end
  if COMPARE[op] then return ('%s %s %s'):format(P, COMPARE[op], L) end
  if LENGTH[op] then return ('length(%s) %s %s'):format(P, LENGTH[op], tonumber(value) or 0) end
  if op == 'contains' then return ('contains(%s, %s)'):format(P, L) end
  if op == 'notcontains' then return ('!contains(%s, %s)'):format(P, L) end
  if op == 'startswith' then return ('startswith(string(%s), %s)'):format(P, L) end
  if op == 'endswith' then return ('endswith(string(%s), %s)'):format(P, L) end
  if op == 'regex' then return ('regextest(%s, string(%s))'):format(quote(value), P) end
  if op == 'haslabel' then return ('hastag(file, %s)'):format(quote(value)) end
  if op == 'infolder' then return ('infolder(file, %s)'):format(quote(value)) end
  if op == 'linksto' then return ('haslink(file, %s)'):format(quote(value)) end
  return 'true'
end

---Expression of a whole tree; nil when the tree filters nothing
---@param node table|nil
---@param types? table<string, string>
---@return string|nil
function M.build(node, types)
  if node == nil then return nil end
  if node.kind ~= 'group' then return M.build_cond(node, types) end
  local parts = {}
  for _, item in ipairs(node.items or {}) do
    local e = M.build(item, types)
    if e then parts[#parts + 1] = '(' .. e .. ')' end
  end
  if #parts == 0 then return nil end
  if node.mode == 'or' then return table.concat(parts, ' or ') end
  if node.mode == 'not' then return '!(' .. table.concat(parts, ' or ') .. ')' end
  return table.concat(parts, ' and ')
end

---Compile a list of trees (combined with `and`) into one predicate
---@param trees (table|nil)[]
---@param types? table<string, string>
---@return (fun(row: any, this: any): boolean)|nil
function M.compile(trees, types)
  local parts = {}
  for _, tree in pairs(trees) do
    local e = M.build(tree, types)
    if e then parts[#parts + 1] = '(' .. e .. ')' end
  end
  if #parts == 0 then return nil end
  local fn = eval.compile(parser.parse_expression(table.concat(parts, ' and ')))
  local truthy = require('fey.query.values').truthy
  return function(row, this) return truthy(fn(eval.new_env(row, this))) end
end

---Check an expression without running it
---@param expr string
---@return string|nil err
function M.validate(expr)
  local ok, err = pcall(function() eval.compile(parser.parse_expression(expr)) end)
  if ok then return nil end
  return (tostring(err):gsub('^query: ', ''))
end

---One line summary of a node for lists
---@param node table
---@return string
function M.describe(node)
  if node.kind == 'group' then
    local label = ({ ['and'] = 'all of', ['or'] = 'any of', ['not'] = 'none of' })[node.mode or 'and'] or 'all of'
    return ('%s (%d)'):format(label, #(node.items or {}))
  end
  if node.kind == 'expr' then return node.expr or '' end
  local op = M.OP_BY_ID[node.op]
  local label = op and op.label or node.op or '?'
  if op and op.arity == 0 then return ('%s %s'):format(node.prop, label) end
  return ('%s %s %s'):format(node.prop or '', label, node.value or '')
end

---A fresh empty group
---@param mode? string
function M.group(mode) return { kind = 'group', mode = mode or 'and', items = {} } end

return M
