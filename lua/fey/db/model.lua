-- Computation behind a database view: rows from the vault, formulas, filters,
-- sorting, grouping, limits and column summaries.
local V = require('fey.query.values')
local ops = require('fey.query.ops')
local parser = require('fey.query.parser')
local eval = require('fey.query.eval')
local pages = require('fey.query.pages')
local filters = require('fey.db.filters')

local NULL = V.NULL

---@class FeyDbModel
---@field vault FeyVault
---@field base table
---@field revision integer
local Model = {}
Model.__index = Model

local M = {}

-- File properties every note has (the ones that make sense as columns)
M.FILE_PROPS = {
  { id = 'file.name', type = 'string' },
  { id = 'file.path', type = 'string' },
  { id = 'file.folder', type = 'string' },
  { id = 'file.ext', type = 'string' },
  { id = 'file.size', type = 'number' },
  { id = 'file.ctime', type = 'date' },
  { id = 'file.mtime', type = 'date' },
  { id = 'file.labels', type = 'list' },
  { id = 'file.heading_labels', type = 'list' },
  { id = 'file.hollow', type = 'string' },
  { id = 'file.outlinks', type = 'list' },
  { id = 'file.inlinks', type = 'list' },
  { id = 'file.aliases', type = 'list' },
  { id = 'file.headings', type = 'list' },
  { id = 'file.link', type = 'link' },
}

---@param vault FeyVault
---@param base table
---@return FeyDbModel
function M.new(vault, base)
  local self = setmetatable({ vault = vault, base = base }, Model)
  self.compiled = {}
  self.revision = false
  return self
end

-- Revision handling ----------------------------------------------------------------

---Drop caches when the index changed. Returns true if anything was dropped.
function Model:sync()
  local spec = self.base.scope
  local rev = (spec == nil or spec == 'current') and (self.vault.revision or 0)
    or require('fey.hollow.scope').revision(spec, self.vault.root)
  local key = vim.json.encode({ rev, spec })
  if key == self.revision then return false end
  self.revision = key
  self.store = pages.scope_store(self.vault, spec)
  self.rows_cache, self.types, self.result_cache, self.note_props = nil, nil, nil, nil
  return true
end

---Call after the base (formulas, filters) changed
function Model:invalidate()
  self.rows_cache, self.types, self.result_cache = nil, nil, nil
  self.compiled = {}
end

-- Properties -------------------------------------------------------------------------

---@return { id: string, kind: string, count?: integer }[]
function Model:properties()
  self:sync()
  if self.note_props then return self.note_props end
  local out = {}
  for _, p in ipairs(M.FILE_PROPS) do
    out[#out + 1] = { id = p.id, kind = 'file' }
  end
  for _, f in ipairs(self.base.formulas or {}) do
    out[#out + 1] = { id = 'formula.' .. f.name, kind = 'formula' }
  end
  -- the properties of every hollow of the scope
  local counts, names = {}, {}
  local rows = require('fey.hollow.scope').collect(self.base.scope, self.vault.root, function(vault)
    return vault:query('SELECT name, COUNT(*) AS c FROM properties GROUP BY name')
  end)
  for _, r in ipairs(rows) do
    if not counts[r.name] then names[#names + 1] = r.name end
    counts[r.name] = (counts[r.name] or 0) + r.c
  end
  table.sort(names, function(a, b)
    if counts[a] ~= counts[b] then return counts[a] > counts[b] end
    return a < b
  end)
  for _, name in ipairs(names) do
    out[#out + 1] = { id = name, kind = 'note', count = counts[name] }
  end
  self.note_props = out
  return out
end

-- Getters ------------------------------------------------------------------------------

---Compiled reader of a property
---@param prop string
---@return fun(row: any): any
function Model:getter(prop)
  local hit = self.compiled[prop]
  if hit then return hit end
  local fn = eval.compile(parser.parse_expression(filters.prop_expr(prop)))
  local g = function(row)
    local v = fn(eval.new_env(row, nil))
    return v
  end
  self.compiled[prop] = g
  return g
end

---Rows with the `formula` object attached
---@return table[]
function Model:all_rows()
  self:sync()
  if self.rows_cache then return self.rows_cache end
  local formulas = self.base.formulas or {}
  local list = self.store:pages()
  if #formulas == 0 then
    self.rows_cache = list
    return list
  end

  local compiled = {}
  local names = {}
  for _, f in ipairs(formulas) do
    local ok, fn = pcall(function() return eval.compile(parser.parse_expression(f.expr or 'null')) end)
    compiled[f.name] = ok and fn or false
    names[#names + 1] = f.name
  end

  local rows = {}
  for i, page in ipairs(list) do
    local fields = {}
    local row = pages.derive(page, fields, { 'formula' })
    local cache = {}
    local depth = 0
    fields.formula = pages.lazy(function(_, k)
      local fn = compiled[k]
      if fn == nil then return nil end
      if cache[k] ~= nil then return cache[k] end
      if fn == false or depth > 8 then return NULL end -- broken formula or a cycle
      depth = depth + 1
      local v = fn(eval.new_env(row, nil))
      depth = depth - 1
      cache[k] = v == nil and NULL or v
      return cache[k]
    end, function() return names end)
    rows[i] = row
  end
  self.rows_cache = rows
  return rows
end

---Type of a property, from a sample of its values
---@param prop string
---@return string
function Model:prop_type(prop)
  self:sync()
  self.types = self.types or {}
  if self.types[prop] then return self.types[prop] end
  for _, p in ipairs(M.FILE_PROPS) do
    if p.id == prop then
      self.types[prop] = p.type
      return p.type
    end
  end
  local rows, get = self:all_rows(), self:getter(prop)
  local seen, n = {}, 0
  for i = 1, #rows do
    local v = get(rows[i])
    if not V.is_null(v) then
      local t = V.typeof(v)
      seen[t] = true
      n = n + 1
      if n >= 300 then break end
    end
  end
  local kinds = vim.tbl_keys(seen)
  local result = 'string'
  if #kinds == 1 then
    result = kinds[1] == 'array' and 'list' or kinds[1]
  elseif #kinds > 1 then
    result = 'mixed'
  end
  self.types[prop] = result
  return result
end

---@return table<string, string>
function Model:type_map()
  local map = {}
  for _, p in ipairs(self:properties()) do
    map[p.id] = self:prop_type(p.id)
  end
  return map
end

-- Compute ---------------------------------------------------------------------------------

---@class FeyDbResult
---@field rows any[] rows after filters, sorting and limit
---@field total integer rows after filters, before the limit
---@field matched integer all rows in the vault
---@field groups? { key: any, first: integer, count: integer }[]
---@field error? string

---@param tbl table
local function sig(tbl) return vim.json.encode(tbl) end

---Apply base and view settings
---@param view table
---@return FeyDbResult
function Model:compute(view)
  self:sync()
  local key = sig({ self.base.filters or vim.NIL, self.base.formulas or vim.NIL, view.filters or vim.NIL, view.sort or vim.NIL, view.group or vim.NIL, view.limit or vim.NIL })
  if self.result_cache and self.result_cache.key == key then return self.result_cache.value end

  local rows = self:all_rows()
  local result = { matched = #rows }

  local ok, err = pcall(function()
    local types = self:type_map()
    local pred = filters.compile({ self.base.filters, view.filters }, types)
    local out = rows
    if pred then
      out = {}
      for i = 1, #rows do
        if pred(rows[i]) then out[#out + 1] = rows[i] end
      end
    end

    -- sort keys: the group first, then the view's sort list
    local keys = {}
    if view.group and view.group.prop then
      keys[#keys + 1] = { get = self:getter(view.group.prop), desc = view.group.dir == 'desc' }
    end
    for _, s in ipairs(view.sort or {}) do
      if s.prop then keys[#keys + 1] = { get = self:getter(s.prop), desc = s.dir == 'desc' } end
    end

    if #keys > 0 then
      local decorated = {}
      for i, row in ipairs(out) do
        local kv = {}
        for k, key_ in ipairs(keys) do
          kv[k] = key_.get(row)
        end
        decorated[i] = { row = row, kv = kv, i = i }
      end
      table.sort(decorated, function(a, b)
        for k, key_ in ipairs(keys) do
          local c = V.compare(a.kv[k], b.kv[k])
          if c ~= 0 then
            if key_.desc then return c > 0 end
            return c < 0
          end
        end
        return a.i < b.i
      end)
      out = {}
      for i, d in ipairs(decorated) do
        out[i] = d.row
      end
    end

    result.total = #out
    if view.limit and view.limit > 0 and #out > view.limit then
      local cut = {}
      for i = 1, view.limit do
        cut[i] = out[i]
      end
      out = cut
    end
    result.rows = out

    if view.group and view.group.prop then
      local get = self:getter(view.group.prop)
      local groups = {}
      for i, row in ipairs(out) do
        local k = get(row)
        local last = groups[#groups]
        if last and V.equals(last.key, k) then
          last.count = last.count + 1
        else
          groups[#groups + 1] = { key = k, first = i, count = 1 }
        end
      end
      result.groups = groups
    end
  end)
  if not ok then
    result.rows, result.total, result.error = {}, 0, (tostring(err):gsub('^query: ', ''))
  end

  self.result_cache = { key = key, value = result }
  return result
end

-- Summaries ----------------------------------------------------------------------------------

M.SUMMARIES = {
  { id = 'count', label = 'Count (all rows)' },
  { id = 'filled', label = 'Filled' },
  { id = 'empty', label = 'Empty' },
  { id = 'unique', label = 'Unique' },
  { id = 'sum', label = 'Sum' },
  { id = 'average', label = 'Average' },
  { id = 'median', label = 'Median' },
  { id = 'min', label = 'Min' },
  { id = 'max', label = 'Max' },
  { id = 'range', label = 'Range' },
  { id = 'stddev', label = 'Standard deviation' },
  { id = 'earliest', label = 'Earliest date' },
  { id = 'latest', label = 'Latest date' },
  { id = 'checked', label = 'Checked (true)' },
  { id = 'unchecked', label = 'Unchecked (false)' },
}

---@param summary string
---@param prop string
---@param rows any[]
---@return any
function Model:summarize(summary, prop, rows)
  local get = self:getter(prop)
  local vals, nums, filled = {}, {}, 0
  for i = 1, #rows do
    local v = get(rows[i])
    vals[i] = v
    if not V.is_null(v) and not (v == '' or (V.is_list(v) and #v == 0)) then filled = filled + 1 end
    if type(v) == 'number' then nums[#nums + 1] = v end
  end

  if summary == 'count' then return #rows end
  if summary == 'filled' then return filled end
  if summary == 'empty' then return #rows - filled end
  if summary == 'unique' then
    local seen = {}
    for _, v in ipairs(vals) do
      seen[ops.tostring(v)] = true
    end
    return vim.tbl_count(seen)
  end
  if summary == 'checked' or summary == 'unchecked' then
    local want = summary == 'checked'
    local n = 0
    for _, v in ipairs(vals) do
      if v == want then n = n + 1 end
    end
    return n
  end
  if summary == 'earliest' or summary == 'latest' then
    local best
    for _, v in ipairs(vals) do
      if V.is_date(v) and (not best or (summary == 'earliest' and v.ts < best.ts) or (summary == 'latest' and v.ts > best.ts)) then
        best = v
      end
    end
    return best == nil and NULL or best
  end

  if #nums == 0 then return NULL end
  if summary == 'sum' then
    local s = 0
    for _, n in ipairs(nums) do s = s + n end
    return s
  end
  if summary == 'average' then
    local s = 0
    for _, n in ipairs(nums) do s = s + n end
    return s / #nums
  end
  if summary == 'min' or summary == 'max' or summary == 'range' then
    local lo, hi = math.huge, -math.huge
    for _, n in ipairs(nums) do
      lo, hi = math.min(lo, n), math.max(hi, n)
    end
    if summary == 'min' then return lo end
    if summary == 'max' then return hi end
    return hi - lo
  end
  if summary == 'median' then
    table.sort(nums)
    local mid = math.floor((#nums + 1) / 2)
    return #nums % 2 == 1 and nums[mid] or (nums[mid] + nums[mid + 1]) / 2
  end
  if summary == 'stddev' then
    local s = 0
    for _, n in ipairs(nums) do s = s + n end
    local mean = s / #nums
    local sq = 0
    for _, n in ipairs(nums) do sq = sq + (n - mean) ^ 2 end
    return math.sqrt(sq / #nums)
  end
  return NULL
end

M.Model = Model
return M
