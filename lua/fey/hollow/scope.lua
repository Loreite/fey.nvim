-- Scopes: which hollows a view looks at.
--
--   current   the hollow itself (default)
--   tree      the hollow and every hollow below it
--   court     the court and every hollow below it, that is all of them
--   { ... }   a list of hollow references, `court:notes:history`; with a trailing `:*` a hollow and
--             everything below it (`court:notes:*`)
--
-- Hollows that set `merge: false` in their settings (see `fey.hollow.tree`) are left out of `tree` and
-- `court`, together with everything below them. The hollow a scope starts from is always in it, and so is
-- a hollow that a list names.
--
-- Rows of the merged functions carry `hollow` (the id of the hollow they came from, `court:notes`) and,
-- when they have a `path`, `abs` (the file to write to).
--
--   local scope = require('fey.hollow.scope')
--   scope.dates('court', nil, { from = t0, to = t1 })
--   scope.tasks('tree', vault.root, { done = false })
--   scope.resolve({ 'court:notes:*', 'court:play' })
local tree = require('fey.hollow.tree')

local M = {}

---@alias FeyScopeSpec 'current'|'tree'|'court'|string[]

---@class FeyScopeHollow
---@field id string canonical id of the hollow
---@field root string
---@field vault FeyVault

---@param root string
---@return FeyVault|nil
local function open(root)
  local vault = require('fey.vault').open(root)
  if vault and vault:open() then return vault end
end

---@param root string
---@param id string
---@return FeyScopeHollow|nil
local function entry_of(root, id)
  local vault = open(root)
  if not vault then return nil end
  return { id = id, root = vault.root, vault = vault }
end

---Add the hollows below `root` (the ones that take part in merged views) to `out`
---@param root string
---@param id string
---@param out FeyScopeHollow[]
---@param seen table<string, boolean>
local function descend(root, id, out, seen)
  for _, child in ipairs(tree.children(root, { merged = true })) do
    local child_root = tree.realpath(child.root)
    if not seen[child_root] then
      seen[child_root] = true
      local child_id = id .. ':' .. child.name
      local entry = entry_of(child_root, child_id)
      if entry then
        out[#out + 1] = entry
        descend(child_root, child_id, out, seen)
      end
    end
  end
end

---The hollows of a scope, opened
---@param spec? FeyScopeSpec
---@param current_root? string the hollow `current` and `tree` start from
---@return FeyScopeHollow[] hollows
---@return string[] errors references that could not be resolved
function M.resolve(spec, current_root)
  spec = spec or 'current'
  local out, errors, seen = {}, {}, {}

  local function add(root, id, with_children)
    root = tree.realpath(root)
    if not seen[root] then
      seen[root] = true
      local entry = entry_of(root, id or tree.id_of(root) or root)
      if entry then out[#out + 1] = entry end
    end
    if with_children then descend(root, id or tree.id_of(root) or root, out, seen) end
  end

  local court = require('fey.hollow.court')
  local function one(item)
    if item == 'current' or item == 'tree' then
      if not current_root then
        errors[#errors + 1] = 'no current hollow'
      else
        add(current_root, nil, item == 'tree')
      end
    elseif item == 'court' then
      local root = court.ensure_dirs()
      if root then add(root, 'court', true) else errors[#errors + 1] = 'the court is switched off' end
    else
      local with_children = false
      local text = item
      if text:sub(-2) == ':*' then
        with_children = true
        text = text:sub(1, -3)
      end
      local root, _, err = tree.resolve_ref(text, current_root)
      if root then
        add(root, nil, with_children)
      else
        errors[#errors + 1] = err or ('cannot resolve ' .. item)
      end
    end
  end

  if type(spec) == 'string' then
    one(spec)
  else
    for _, item in ipairs(spec) do
      one(item)
    end
  end
  return out, errors
end

---A number that changes when the index of any hollow of the scope changes
---@param spec? FeyScopeSpec
---@param current_root? string
---@return integer
function M.revision(spec, current_root)
  local sum = 0
  for _, v in ipairs((M.resolve(spec, current_root))) do
    sum = sum + (v.vault.revision or 0)
  end
  return sum
end

---Rows of the same read from every hollow of a scope, each with `hollow` and, when it has a `path`, `abs`
---@param spec? FeyScopeSpec
---@param current_root? string
---@param fn fun(vault: FeyVault, id: string): table[]
---@return table[]
function M.collect(spec, current_root, fn)
  local out = {}
  for _, v in ipairs((M.resolve(spec, current_root))) do
    for _, row in ipairs(fn(v.vault, v.id)) do
      row.hollow = v.id
      if row.path then row.abs = v.vault:abs(row.path) end
      out[#out + 1] = row
    end
  end
  return out
end

---A statement run against the index of every hollow, the rows together. It has to stand on its own inside
---one hollow (no joins across hollows).
---@param spec? FeyScopeSpec
---@param current_root? string
---@param sql string
---@param params? table
---@return table[]
function M.query(spec, current_root, sql, params)
  return M.collect(spec, current_root, function(vault) return vault:query(sql, params) end)
end

---Dates of the hollows of a scope, see `FeyVault:dates`; ordered by start, then hollow, path and line
---@param spec? FeyScopeSpec
---@param current_root? string
---@param opts? table
---@return table[]
function M.dates(spec, current_root, opts)
  local rows = M.collect(spec, current_root, function(vault) return vault:dates(opts) end)
  table.sort(rows, function(a, b)
    if a.start_ts ~= b.start_ts then return a.start_ts < b.start_ts end
    if a.hollow ~= b.hollow then return a.hollow < b.hollow end
    if a.path ~= b.path then return a.path < b.path end
    return a.line < b.line
  end)
  return rows
end

---Source blocks of the hollows of a scope, see `FeyVault:blocks`
---@param spec? FeyScopeSpec
---@param current_root? string
---@param opts? table
---@return table[]
function M.blocks(spec, current_root, opts)
  return M.collect(spec, current_root, function(vault) return vault:blocks(opts) end)
end

---Tasks of the hollows of a scope, see `FeyVault:tasks`
---@param spec? FeyScopeSpec
---@param current_root? string
---@param opts? table
---@return table[]
function M.tasks(spec, current_root, opts)
  return M.collect(spec, current_root, function(vault) return vault:tasks(opts) end)
end

---Labels of the hollows of a scope with the number of files using them and the hollows they are in
---@param spec? FeyScopeSpec
---@param current_root? string
---@param opts? table see `FeyVault:labels`
---@return { label: string, count: integer, hollows: string[] }[]
function M.labels(spec, current_root, opts)
  local by_label, order = {}, {}
  for _, v in ipairs((M.resolve(spec, current_root))) do
    for _, row in ipairs(v.vault:labels(opts)) do
      local entry = by_label[row.label]
      if not entry then
        entry = { label = row.label, count = 0, hollows = {} }
        by_label[row.label] = entry
        order[#order + 1] = entry
      end
      entry.count = entry.count + row.count
      table.insert(entry.hollows, v.id)
    end
  end
  table.sort(order, function(a, b) return a.label:lower() < b.label:lower() end)
  return order
end

---Links and section tags that point at a file (or one of its headings) from every hollow of a scope,
---including the links that name the hollow (`court:notes/a.fey`)
---@param spec? FeyScopeSpec
---@param current_root? string
---@param target_root string the hollow of the file
---@param path string
---@param signature? string
---@return table[] rows with `hollow`, `abs`, `path`, `line`, `kind`, `target`
function M.backlinks(spec, current_root, target_root, path, signature)
  target_root = tree.realpath(target_root)
  local out = {}
  for _, v in ipairs((M.resolve(spec, current_root))) do
    local rows
    if tree.realpath(v.root) == target_root then
      rows = v.vault:backlinks(path, signature)
    else
      rows = v.vault:foreign_backlinks(target_root, path, signature)
    end
    for _, row in ipairs(rows) do
      row.hollow = v.id
      row.abs = v.vault:abs(row.path)
      out[#out + 1] = row
    end
  end
  return out
end

return M
