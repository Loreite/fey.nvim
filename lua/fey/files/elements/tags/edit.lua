-- Reading and rewriting tags in a buffer, and the metadata region of a heading.
--
-- Fey headings have no slots for a todo keyword, labels, planning dates or properties: those are
-- tags. The metadata region of a heading is where they live:
--
--   * the tags in the title of the heading
--       I.A. {# status, TODO, A #} Write the report {# labels, work #}
--   * the leading lines of its body that hold nothing but tags (blank lines between them are fine)
--       {# scheduled, 2026-10-06 Tue #}
--       {# prop; effort: 2h #}
--
-- The region ends at the first body element that is anything else (text, a list, a table, ...).
--
-- Edits are targeted: `set_key` and friends only touch the piece of the head they change, so the
-- formatting of a multi-line head or the order of its keys is left alone. Every edit changes the
-- buffer, so a `FeyTag` read before it is stale afterwards: read it again.
local config = require('fey.config')

local M = {}

M.TAG_TYPES = { scope_tag = true, line_tag = true, block_tag = true, pair_tag = true }

local CLOSERS = '%]})>'
local WORD = '^[a-zA-Z_][a-zA-Z0-9_]*$'

local tag_query

local function parse_tag_node(bufnr, node) return require('fey.files.elements.tags').parse_tag_node(bufnr, node) end

---The part of a tag that holds its name, values and keys
---@param node TSNode
---@return TSNode
function M.head(node) return node:type() == 'pair_tag' and node:field('open')[1] or node end

local function text(bufnr, node) return vim.treesitter.get_node_text(node, bufnr) end

---@param bufnr integer
---@return TSNode|nil root
local function get_root(bufnr)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, 'fey', {})
  if not ok or not parser then return nil end
  local trees = parser:parse()
  return trees and trees[1] and trees[1]:root() or nil
end

-- Reading -------------------------------------------------------------------

---The innermost tag around a position (0-based row and column). Works in a buffer that has syntax
---errors elsewhere. With `opts.line` a position outside any tag falls back to the first tag at or
---after it on the same line (what makes tags in the cells of a table work).
---@param bufnr integer
---@param row integer
---@param col integer
---@param opts? { line?: boolean, name?: string }
---@return FeyTag|nil
function M.at(bufnr, row, col, opts)
  opts = opts or {}
  local root = get_root(bufnr)
  if not root then return nil end

  local function wanted(node)
    if not opts.name then return true end
    local name = M.head(node):field('name')[1]
    return name ~= nil and text(bufnr, name) == opts.name
  end

  -- the character at the position first (a zero-width lookup at the start of a line resolves to the
  -- end of the line before), then the position itself (past the end of a tag, in insert mode)
  for _, last_col in ipairs({ col + 1, col }) do
    local node = root:descendant_for_range(row, col, row, last_col)
    while node do
      if M.TAG_TYPES[node:type()] and not node:has_error() and wanted(node) then return parse_tag_node(bufnr, node) end
      node = node:parent()
    end
  end

  if not opts.line then return nil end
  tag_query = tag_query or vim.treesitter.query.parse('fey', '[(scope_tag) (pair_tag) (line_tag) (block_tag)] @tag')
  local best, best_col
  for _, n in tag_query:iter_captures(root, bufnr, row, row + 1) do
    local sr, sc = n:start()
    if sr == row and sc >= col and not n:has_error() and wanted(n) and (not best or sc < best_col) then
      best, best_col = n, sc
    end
  end
  return best and parse_tag_node(bufnr, best) or nil
end

---The innermost tag around the cursor, see `at`
---@param bufnr? integer
---@param opts? { line?: boolean, name?: string }
---@return FeyTag|nil
function M.at_cursor(bufnr, opts)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  return M.at(bufnr, row - 1, col, opts)
end

---@param h TSNode|{ node: fun(self): TSNode }
---@return TSNode|nil section
local function section_of(h)
  if type(h) == 'table' and h.node then h = h:node() end
  ---@cast h TSNode
  if h:type() == 'heading' then return h:parent() end
  if h:type() == 'section' then return h end
end

---@class FeyMetaTag:FeyTag
---@field region 'title'|'body' where the tag was found
---@field row integer 0-based line of the tag

---The tags of the metadata region of a heading (see the top of this file), in document order
---@param bufnr integer
---@param heading TSNode|table a `heading` or `section` node, or an object with a `node()` method
---@param opts? { name?: string, region?: 'title'|'body' }
---@return FeyMetaTag[] tags
---@return integer|nil last_row 0-based line of the last tag line in the body part of the region
function M.for_heading(bufnr, heading, opts)
  opts = opts or {}
  local section = section_of(heading)
  if not section then return {}, nil end

  local entries, last_row = require('fey.files.elements.tags.region').entries(section)
  local out = {}
  for _, entry in ipairs(entries) do
    if not opts.region or opts.region == entry.region then
      local tag = parse_tag_node(bufnr, entry.node)
      if not opts.name or tag.name == opts.name then
        tag.region = entry.region
        tag.row = entry.node:start()
        table.insert(out, tag)
      end
    end
  end
  return out, last_row
end

-- Writing text --------------------------------------------------------------

---Escape one word of a tag head: `\`, `,` and `;` have a meaning there
---@param s string
local function escape(s) return (s:gsub('[\\,;]', '\\%0')) end

---@param s any
---@param end_of_tag? string the end of the head, e.g. `#}`, `#]` or `]#`: a blank and this in a value would end the tag
---@param pair? boolean the tag is the opener of a pair tag. Its closing bracket may not start a word (the text `[ name, a ] b` is text, the head of a pair opener ends at its sign and bracket, but the scanner reads a tag as a pair opener or not before it reads the head, and takes a bracket word as no opener)
---@return string|nil escaped
---@return string|nil err
local function head_word(s, end_of_tag, pair)
  s = vim.trim(tostring(s))
  if s == '' then return nil, 'empty value' end
  if s:find('[\r\n]') then return nil, 'a tag value cannot hold a line break: ' .. s end
  if end_of_tag and (s:find('%s' .. vim.pesc(end_of_tag)) or s:find('^' .. vim.pesc(end_of_tag))) then
    return nil, 'a tag value cannot hold the end of the tag: ' .. s
  end
  local close = end_of_tag and end_of_tag:sub(-1)
  if pair and close and (s:find('^' .. vim.pesc(close)) or s:find('%s' .. vim.pesc(close))) then
    return nil, 'a word of the head of a pair tag cannot start with its closing bracket: ' .. s
  end
  return escape(s)
end

---Text of a scope tag, on one line: `{# name, v1, v2; key: value #}`
---@param name string
---@param values? string[]
---@param key_values? table<string, any>
---@param opts? { sigil?: string, bracket?: string, order?: string[] } `bracket` is the open bracket, default `{`; `order` the order of the keys, default sorted
---@return string|nil text
---@return string|nil err
function M.build(name, values, key_values, opts)
  opts = opts or {}
  local sigil = opts.sigil or '#'
  local open = opts.bracket or '{'
  local close = ({ ['['] = ']', ['{'] = '}', ['('] = ')', ['<'] = '>' })[open]
  if not close then return nil, 'unknown bracket: ' .. open end
  if not name:match(WORD) then return nil, 'invalid tag name: ' .. name end

  local parts = { open .. sigil .. ' ' .. name }
  for _, v in ipairs(values or {}) do
    local word, err = head_word(v, sigil .. close)
    if not word then return nil, err end
    table.insert(parts, ', ' .. word)
  end

  key_values = key_values or {}
  local keys = opts.order
  if not keys then
    keys = vim.tbl_keys(key_values)
    table.sort(keys)
  end
  for _, k in ipairs(keys) do
    local v = key_values[k]
    if v ~= nil then
      if not k:match(WORD) then return nil, 'invalid tag key: ' .. k end
      local word, err = head_word(v, sigil .. close)
      if not word then return nil, err end
      table.insert(parts, '; ' .. k .. ': ' .. word)
    end
  end
  return table.concat(parts) .. ' ' .. sigil .. close
end

-- Targeted edits ------------------------------------------------------------

---The `tag_end` of the head
---@param head TSNode
---@return TSNode|nil
local function tag_end_of(head)
  for child in head:iter_children() do
    if child:type() == 'tag_end' then return child end
  end
end

---Children of the head up to its tag_end, in order
---@param head TSNode
---@return TSNode[]
local function head_children(head)
  local out = {}
  for child in head:iter_children() do
    if child:type() == 'tag_end' then break end
    table.insert(out, child)
  end
  return out
end

---@param bufnr integer
---@param from TSNode|integer[] node, or { row, col } for the start
---@param to TSNode|integer[] node, or { row, col } for the end
---@param replacement string
local function replace_range(bufnr, from, to, replacement)
  local sr, sc, er, ec
  if type(from) == 'table' and from[1] then
    sr, sc = from[1], from[2]
  else
    sr, sc = from:start()
  end
  if type(to) == 'table' and to[1] then
    er, ec = to[1], to[2]
  else
    er, ec = to:end_()
  end
  vim.api.nvim_buf_set_text(bufnr, sr, sc, er, ec, vim.split(replacement, '\n', { plain = true }))
end

---@param tag FeyTag
---@return string|nil sigil the tag sigil of a tag, used to check values against its end
local function sigil_of(tag)
  local tag_end = tag.head and tag_end_of(tag.head)
  if not tag_end then return nil end
  local t = vim.trim(text(tag.bufnr, tag_end))
  return t ~= '' and t or nil -- the sigil and the close bracket, e.g. `#}`
end

---@param tag FeyTag
---@param key string
---@return TSNode|nil
local function find_key(tag, key)
  local found
  for _, kv in ipairs(tag.head:field('key_value')) do
    local k = kv:field('key')[1]
    if k and vim.trim(text(tag.bufnr, k)) == key then found = kv end
  end
  return found
end

---Delete a head element together with the delimiter in front of it
---@param tag FeyTag
---@param node TSNode a value or key_value of the head
local function remove_element(tag, node)
  local children = head_children(tag.head)
  for i, child in ipairs(children) do
    if child:id() == node:id() then
      local delim = children[i - 1]
      local before = children[i - 2]
      if delim and delim:type() == 'tag_delimiter' and before then
        replace_range(tag.bufnr, { before:end_() }, node, '')
      else
        replace_range(tag.bufnr, node, node, '')
      end
      return
    end
  end
end

---Set (or, with a nil value, remove) `key` of the head: `{# name; key: value #}`. The value
---of an existing key is replaced in place, a new key goes to the end of the head.
---@param tag FeyTag
---@param key string
---@param value any
---@return boolean ok
---@return string|nil err
function M.set_key(tag, key, value)
  if not key:match(WORD) then return false, 'invalid tag key: ' .. key end
  local kv = find_key(tag, key)

  if value == nil then
    if not kv then return false, 'no such key: ' .. key end
    remove_element(tag, kv)
    return true
  end

  local word, err = head_word(value, sigil_of(tag), tag.type == 'pair_tag')
  if not word then return false, err end

  if kv then
    local old = kv:field('value')[1]
    local lead = old and text(tag.bufnr, old):match('^%s*') or ' '
    if not old then return false, 'key without a value: ' .. key end
    replace_range(tag.bufnr, old, old, lead .. word)
    return true
  end

  local children = head_children(tag.head)
  local last = children[#children]
  if not last then return false, 'tag without a name' end
  local entry = key .. ': ' .. word
  if last:type() == 'tag_delimiter' then
    local delim = text(tag.bufnr, last)
    if delim == ';' then
      replace_range(tag.bufnr, { last:end_() }, { last:end_() }, ' ' .. entry)
    else -- a trailing `,` cannot be followed by a key: it becomes the key separator
      replace_range(tag.bufnr, last, last, '; ' .. entry)
    end
  else
    replace_range(tag.bufnr, { last:end_() }, { last:end_() }, '; ' .. entry)
  end
  return true
end

---Set the plain value at `index` (1 based). `index == #tag.values + 1` appends a value.
---@param tag FeyTag
---@param index integer
---@param value any
---@return boolean ok
---@return string|nil err
function M.set_value(tag, index, value)
  local word, err = head_word(value, sigil_of(tag), tag.type == 'pair_tag')
  if not word then return false, err end
  local values = tag.head:field('value')
  local node = values[index]
  if node then
    local lead = text(tag.bufnr, node):match('^%s*')
    replace_range(tag.bufnr, node, node, lead .. word)
    return true
  end
  if index ~= #values + 1 then return false, 'no value at index ' .. index end
  local anchor = values[#values] or tag.head:field('name')[1]
  if not anchor then return false, 'tag without a name' end
  replace_range(tag.bufnr, { anchor:end_() }, { anchor:end_() }, ', ' .. word)
  return true
end

---@param tag FeyTag
---@param index integer
---@return boolean ok
---@return string|nil err
function M.remove_value(tag, index)
  local node = tag.head:field('value')[index]
  if not node then return false, 'no value at index ' .. index end
  remove_element(tag, node)
  return true
end

---Rename a tag
---@param tag FeyTag
---@param name string
---@return boolean ok
---@return string|nil err
function M.rename(tag, name)
  if not name:match(WORD) then return false, 'invalid tag name: ' .. name end
  local node = tag.head:field('name')[1]
  if not node then return false, 'tag without a name' end
  replace_range(tag.bufnr, node, node, name)
  return true
end

---The bracket and the sigil a scope tag is written with, `{` and `#` for `{# name #}`, to write a
---tag that looks the same
---@param tag FeyTag
---@return { bracket: string, sigil: string }|nil
function M.style(tag)
  if tag.type ~= 'scope_tag' then return nil end
  local start = tag.head and tag.head:field('tag_closure')[1]
  local t = start and text(tag.bufnr, start) or ''
  local bracket, sigil = t:sub(1, 1), t:sub(2, 2)
  if bracket == '' or sigil == '' then return nil end
  return { bracket = bracket, sigil = sigil }
end

---Replace the whole text of a scope or line tag
---@param tag FeyTag
---@param text string
---@return boolean ok
---@return string|nil err
function M.replace(tag, text)
  if tag.type ~= 'scope_tag' and tag.type ~= 'line_tag' then return false, 'only scope and line tags can be replaced' end
  replace_range(tag.bufnr, tag.node, tag.node, text)
  return true
end

---Delete a scope or line tag (and the line, when it was the only thing on it)
---@param tag FeyTag
---@return boolean ok
---@return string|nil err
function M.remove(tag)
  if tag.type ~= 'scope_tag' and tag.type ~= 'line_tag' then return false, 'only scope and line tags can be removed' end
  local bufnr = tag.bufnr
  local sr, sc, er, ec = tag.node:range()
  local first = vim.api.nvim_buf_get_lines(bufnr, sr, sr + 1, false)[1] or ''
  local last = vim.api.nvim_buf_get_lines(bufnr, er, er + 1, false)[1] or ''
  local before, after = first:sub(1, sc), last:sub(ec + 1)

  if before:match('^%s*$') and after:match('^%s*$') then
    local total = vim.api.nvim_buf_line_count(bufnr)
    if er + 1 < total then
      vim.api.nvim_buf_set_lines(bufnr, sr, er + 1, false, {})
    else -- the last line of the buffer: leave an empty one rather than none
      vim.api.nvim_buf_set_lines(bufnr, sr, er + 1, false, { '' })
    end
    return true
  end

  -- inline: take one blank with it
  if after:match('^[ \t]') then
    ec = ec + #after:match('^[ \t]+')
  elseif before:match('[ \t]$') then
    sc = sc - #before:match('[ \t]+$')
  end
  vim.api.nvim_buf_set_text(bufnr, sr, sc, er, ec, { '' })
  return true
end

-- Adding to a heading ---------------------------------------------------------

---The indentation of the lines under a heading
---@param bufnr integer
---@param head TSNode heading
local function body_indent(bufnr, head)
  local sig = head:field('signature')[1]
  local _, end_col = sig:end_()
  return config:get_indent(end_col + 1, bufnr)
end

---Add text to the title of a heading: at its end, or in front of its first word with
---`opts.first` (where the status goes).
---@param bufnr integer
---@param heading TSNode|table
---@param tag_text string
---@param opts? { first?: boolean }
---@return boolean ok
function M.add_to_title(bufnr, heading, tag_text, opts)
  opts = opts or {}
  local section = section_of(heading)
  local head = section and section:field('heading')[1]
  if not head then return false end
  local title = head:field('title')[1]

  if title and opts.first then
    local r, c = title:start()
    vim.api.nvim_buf_set_text(bufnr, r, c, r, c, { tag_text .. ' ' })
  elseif title then
    local r, c = title:end_()
    vim.api.nvim_buf_set_text(bufnr, r, c, r, c, { ' ' .. tag_text })
  else
    local r = head:start()
    local line = vim.api.nvim_buf_get_lines(bufnr, r, r + 1, false)[1] or ''
    local trimmed = line:gsub('%s+$', '')
    vim.api.nvim_buf_set_text(bufnr, r, #trimmed, r, #line, { ' ' .. tag_text })
  end
  return true
end

---Add a line of tags to the metadata region of a heading: after the last tag line of the region,
---or directly under the heading when it has none yet.
---@param bufnr integer
---@param heading TSNode|table
---@param tag_text string|string[]
---@return integer|nil row 0-based line of the (first) new line
function M.add_to_region(bufnr, heading, tag_text)
  local section = section_of(heading)
  local head = section and section:field('heading')[1]
  if not head then return nil end
  local _, last_row = M.for_heading(bufnr, section, { region = 'body' })

  local row
  local indent
  if last_row then
    row = last_row + 1
    local line = vim.api.nvim_buf_get_lines(bufnr, last_row, last_row + 1, false)[1] or ''
    indent = line:match('^%s*')
  else
    local er, ec = head:end_()
    row = (ec == 0 and er or er + 1)
    indent = body_indent(bufnr, head)
  end

  local lines = type(tag_text) == 'table' and tag_text or { tag_text }
  lines = vim.tbl_map(function(l) return indent .. l end, lines)
  vim.api.nvim_buf_set_lines(bufnr, row, row, false, lines)
  return row
end

return M
