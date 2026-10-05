-- Tree-sitter model for the Fey navigator.
--
-- Turns the fey AST into navigable "items". Node types come straight from
-- tree-sitter-fey/grammar.js:
--
--   section (heading + body + sub-sections)   list > listitem
--   block (fenced)                             table > row (row_block is transparent)
--   line_tag, scope_tag, pair_tag, block_tag   paragraph
--
-- An item never outlives the tree it came from; anything that must survive
-- an edit is converted to a plain-data ref with M.to_ref().

local M = {}

---@class FeyNavItem
---@field kind string            'category'|'heading'|'list'|'listitem'|'block'|'table'|'row'|'tag'|'paragraph'
---@field label string
---@field category? string       for kind == 'category'
---@field node? TSNode
---@field type? string           TS node type
---@field range? integer[]       { start_row, start_col, end_row, end_col } (0-based, end exclusive)
---@field id? string             TSNode:id()
---@field _children? FeyNavItem[]
---@field _local? FeyNavItem[]

---@class FeyNavRef  plain-data identity of an item (safe to keep across edits)
---@field kind string
---@field category? string
---@field type? string
---@field range? integer[]
---@field id? string
---@field path? string
---@field label? string

local TAG_TYPES = { line_tag = true, scope_tag = true, pair_tag = true, block_tag = true }

local KIND_BY_TYPE = {
  section = 'heading',
  list = 'list',
  listitem = 'listitem',
  block = 'block',
  table = 'table',
  row = 'row',
  paragraph = 'paragraph',
  line_tag = 'tag',
  scope_tag = 'tag',
  pair_tag = 'tag',
  block_tag = 'tag',
}

local function type_set(...)
  local s = {}
  for _, t in ipairs({ ... }) do
    s[t] = true
  end
  return s
end

-- Root categories, in display order.
M.categories = {
  { name = 'headings', title = 'Headings', types = type_set('section') },
  { name = 'lists', title = 'Lists', types = type_set('list') },
  { name = 'blocks', title = 'Blocks', types = type_set('block') },
  { name = 'tables', title = 'Tables', types = type_set('table') },
  { name = 'tags', title = 'Tags', types = TAG_TYPES },
}

local CATEGORY_BY_NAME = {}
for _, c in ipairs(M.categories) do
  CATEGORY_BY_NAME[c.name] = c
end

-- Anything that shows up in a local (<Tab>) view.
local OBJECT_TYPES = type_set('section', 'paragraph', 'list', 'block', 'table', 'line_tag', 'scope_tag', 'pair_tag',
  'block_tag')

-- Never descend into these while collecting: a heading line belongs to its
-- section, the pair delimiters to their pair.
local SKIP = type_set('heading', 'pair_open', 'pair_close', 'bullet', 'signature')

---@class FeyNavModel
---@field bufnr integer
---@field root TSNode
---@field changedtick integer
local Model = {}
Model.__index = Model

--- Parse `bufnr` with the fey parser.
---@param bufnr integer
---@return FeyNavModel|nil model, string|nil err
function M.new(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil, 'invalid buffer'
  end
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, 'fey', { error = false })
  if not ok or not parser then
    return nil, 'no fey tree-sitter parser available for this buffer'
  end
  local ok_parse, trees = pcall(function()
    return parser:parse()
  end)
  if not ok_parse or not trees or not trees[1] then
    return nil, 'failed to parse buffer'
  end
  return setmetatable({
    bufnr = bufnr,
    root = trees[1]:root(),
    changedtick = vim.api.nvim_buf_get_changedtick(bufnr),
  }, Model), nil
end

-- ---------------------------------------------------------------------------
-- Collection helpers
-- ---------------------------------------------------------------------------

--- Outermost named descendants of `node` that satisfy `types`, in document
--- order. A match is collected and not descended into.
---@param node TSNode
---@param types table<string, boolean>
---@return TSNode[]
local function outermost(node, types)
  local out = {}
  local function walk(n)
    for child in n:iter_children() do
      if child:named() then
        local t = child:type()
        if types[t] then
          out[#out + 1] = child
        elseif not SKIP[t] then
          walk(child)
        end
      end
    end
  end
  walk(node)
  return out
end

-- ---------------------------------------------------------------------------
-- Labels
-- ---------------------------------------------------------------------------

local function clean(s)
  return (s:gsub('%s+', ' '):gsub('^ ', ''):gsub(' $', ''))
end

function Model:line(row)
  return vim.api.nvim_buf_get_lines(self.bufnr, row, row + 1, false)[1] or ''
end

---@param node TSNode
function Model:first_line(node)
  local sr, sc, er, ec = node:range()
  local line = self:line(sr)
  if er == sr then
    return line:sub(sc + 1, ec)
  end
  return line:sub(sc + 1)
end

function Model:text(sr, sc, er, ec)
  local ok, lines = pcall(vim.api.nvim_buf_get_text, self.bufnr, sr, sc, er, ec, {})
  return ok and table.concat(lines, ' ') or ''
end

local function child_of_type(node, t)
  for child in node:iter_children() do
    if child:type() == t then
      return child
    end
  end
end

-- Text of a tag's head, from its opener up to the first tag_end.
---@param node TSNode
function Model:tag_head(node)
  local head = node
  if node:type() == 'pair_tag' then
    head = child_of_type(node, 'pair_open') or node
  end
  local sr, sc = head:range()
  local tag_end = child_of_type(head, 'tag_end')
  if tag_end then
    local _, _, er, ec = tag_end:range()
    return clean(self:text(sr, sc, er, ec))
  end
  return clean(self:first_line(head))
end

---@param node TSNode
---@return string
function Model:label(node)
  local t = node:type()
  if t == 'list' then
    local items = 0
    for child in node:iter_children() do
      if child:type() == 'listitem' then
        items = items + 1
      end
    end
    return string.format('%s  (%d item%s)', clean(self:first_line(node)), items, items == 1 and '' or 's')
  elseif t == 'table' then
    local first = child_of_type(node, 'row')
    local cols = 0
    if first then
      for child in first:iter_children() do
        if child:type() == 'cell' then
          cols = cols + 1
        end
      end
    end
    local rows = #outermost(node, { row = true })
    return string.format('%s  (%d×%d)', clean(self:first_line(node)), rows, cols)
  elseif t == 'block' then
    local sr, _, er = node:range()
    return string.format('%s  (%d lines)', clean(self:first_line(node)), er - sr)
  elseif TAG_TYPES[t] then
    local head = self:tag_head(node)
    if t == 'pair_tag' then
      return head .. ' …'
    end
    return head
  end
  -- section (heading line), listitem, row, paragraph: their first line
  return clean(self:first_line(node))
end

-- ---------------------------------------------------------------------------
-- Items
-- ---------------------------------------------------------------------------

---@param node TSNode
---@return FeyNavItem
function Model:item(node)
  local t = node:type()
  return {
    kind = KIND_BY_TYPE[t] or t,
    type = t,
    node = node,
    range = { node:range() },
    id = node:id(),
    label = self:label(node),
  }
end

function Model:items(nodes)
  local out = {}
  for i, n in ipairs(nodes) do
    out[i] = self:item(n)
  end
  return out
end

--- Root view: one item per non-empty category.
---@return FeyNavItem[]
function Model:root_items()
  local out = {}
  for _, cat in ipairs(M.categories) do
    local n = #outermost(self.root, cat.types)
    if n > 0 then
      out[#out + 1] = { kind = 'category', category = cat.name, label = cat.title, count = n }
    end
  end
  return out
end

--- `l`: the item's own hierarchy (sub-headings, child list items, rows,
--- nested tags). Empty for leaves.
---@param item FeyNavItem
---@return FeyNavItem[]
function Model:children(item)
  if item._children then
    return item._children
  end
  local nodes = {}
  if item.kind == 'category' then
    nodes = outermost(self.root, CATEGORY_BY_NAME[item.category].types)
  else
    local node, t = item.node, item.type
    if t == 'section' then
      for child in node:iter_children() do
        if child:type() == 'section' then
          nodes[#nodes + 1] = child
        end
      end
    elseif t == 'list' then
      for child in node:iter_children() do
        if child:type() == 'listitem' then
          nodes[#nodes + 1] = child
        end
      end
    elseif t == 'listitem' then
      for _, list in ipairs(outermost(node, { list = true })) do
        for child in list:iter_children() do
          if child:type() == 'listitem' then
            nodes[#nodes + 1] = child
          end
        end
      end
    elseif t == 'table' then
      nodes = outermost(node, { row = true })
    elseif TAG_TYPES[t] or t == 'paragraph' then
      nodes = outermost(node, TAG_TYPES)
    end
  end
  item._children = self:items(nodes)
  return item._children
end

--- `<Tab>`: every top-level text object inside the item's boundaries.
---@param item FeyNavItem
---@return FeyNavItem[]
function Model:local_children(item)
  if item._local then
    return item._local
  end
  local nodes
  if item.kind == 'category' then
    return self:children(item)
  elseif item.type == 'list' or item.type == 'table' then
    return self:children(item)
  elseif item.type == 'block' or item.type == 'row' then
    nodes = {}
  else
    nodes = outermost(item.node, OBJECT_TYPES)
  end
  item._local = self:items(nodes)
  return item._local
end

--- Last buffer row (0-based, inclusive) covered by a range.
---@param range integer[]
function M.last_row(range)
  local sr, _, er, ec = unpack(range)
  if ec == 0 and er > sr then
    return er - 1
  end
  return er
end

-- ---------------------------------------------------------------------------
-- Refs and matching (AST drift reconciliation)
-- ---------------------------------------------------------------------------

---@param node TSNode
local function node_path(node)
  local parts = {}
  local cur = node
  while cur do
    local parent = cur:parent()
    if not parent then
      break
    end
    local idx = 0
    for i = 0, parent:named_child_count() - 1 do
      local c = parent:named_child(i)
      if c and c:id() == cur:id() then
        idx = i
        break
      end
    end
    table.insert(parts, 1, cur:type() .. ':' .. idx)
    cur = parent
  end
  return table.concat(parts, '/')
end

---@param item FeyNavItem
---@return FeyNavRef
function M.to_ref(item)
  return {
    kind = item.kind,
    category = item.category,
    type = item.type,
    range = item.range and vim.deepcopy(item.range) or nil,
    id = item.id,
    path = item.node and node_path(item.node) or nil,
    label = item.label,
  }
end

local function same_range(a, b)
  return a and b and a[1] == b[1] and a[2] == b[2] and a[3] == b[3] and a[4] == b[4]
end

local function norm(s)
  return (s or ''):lower():gsub('%s+', ' ')
end

-- Labels of headings carry their content; compare without the trailing
-- "(N items)" style counters, which change on every edit.
local function core_label(s)
  return norm(s):gsub('%s*%(.-%)%s*$', ''):gsub('%s*…$', '')
end

local function nearest(ref, items, pred)
  local best, best_d
  for i, it in ipairs(items) do
    if pred(it) then
      local d = math.abs((it.range and it.range[1] or 0) - (ref.range and ref.range[1] or 0))
      if not best_d or d < best_d then
        best, best_d = i, d
      end
    end
  end
  return best, best_d
end

--- Find `ref` in `items`. Returns the index and the tier that matched:
---   1  same node id, or same node path and exact range
---   2  same type and exact range
---   3  same type and same title/content, nearest by line
---   4  same type, nearby (<= 3 lines away) with a similar label prefix
---@param ref FeyNavRef
---@param items FeyNavItem[]
---@return integer|nil index, integer|nil tier
function M.find(ref, items)
  if not ref then
    return nil
  end
  if ref.kind == 'category' then
    for i, it in ipairs(items) do
      if it.kind == 'category' and it.category == ref.category then
        return i, 1
      end
    end
    return nil
  end
  for i, it in ipairs(items) do
    if it.type == ref.type and it.id == ref.id then
      return i, 1
    end
  end
  for i, it in ipairs(items) do
    if it.type == ref.type and same_range(it.range, ref.range) and it.node and node_path(it.node) == ref.path then
      return i, 1
    end
  end
  for i, it in ipairs(items) do
    if it.type == ref.type and same_range(it.range, ref.range) then
      return i, 2
    end
  end
  local want = core_label(ref.label)
  local i = nearest(ref, items, function(it)
    return it.type == ref.type and core_label(it.label) == want
  end)
  if i then
    return i, 3
  end
  local prefix = want:sub(1, 8)
  local j, d = nearest(ref, items, function(it)
    return it.type == ref.type and #prefix > 0 and core_label(it.label):sub(1, #prefix) == prefix
  end)
  if j and d <= 3 then
    return j, 4
  end
  return nil
end

M.Model = Model
M.outermost = outermost
return M
