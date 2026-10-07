-- Footnotes. A reference is a scope tag with the label. A definition is any tag with the label that has a body,
-- written in the form you like:
--
--   The result is odd {@ fn, 1 @}.
--
--   [ fn, 1 #]          a pair tag
--   Measured twice.
--   [# fn ]
--
--   #[ fn, 1 ] Measured twice. #           a line tag
--
--   [ fn, 1 ]#                             a block tag, the text indented
--       Measured twice.
--
-- Open at point (`<prefix>o`) on a reference jumps to its definition (and offers to make one), on a definition
-- it jumps back to the first reference. `<prefix>nf` writes a reference at the cursor and a new definition.
-- The tag name is `fey_footnote_tag_name`.
local config = require('fey.config')

local M = {}

---@class FeyFootnoteTag
---@field label string
---@field form 'scope'|'pair'|'line'|'block' the tag form: `scope` is a reference, the others are definitions
---@field is_reference boolean
---@field node TSNode
---@field row integer 0-based first line
---@field col integer
---@field end_row integer

local query

---@return vim.treesitter.Query
local function get_query()
  query = query or vim.treesitter.query.parse('fey', '[(scope_tag) (line_tag) (block_tag) (pair_tag)] @tag')
  return query
end

---@param bufnr integer
---@param node TSNode
---@return FeyFootnoteTag|nil
local function read(bufnr, node)
  local head = node:type() == 'pair_tag' and node:field('open')[1] or node
  local name = head and head:field('name')[1]
  if not name or vim.treesitter.get_node_text(name, bufnr) ~= config.fey_footnote_tag_name then return nil end
  local value = head:field('value')[1]
  if not value then return nil end
  local label = vim.trim(vim.treesitter.get_node_text(value, bufnr))
  if label == '' then return nil end
  local row, col, end_row = node:range()
  local form = ({ scope_tag = 'scope', pair_tag = 'pair', line_tag = 'line', block_tag = 'block' })[node:type()]
  return {
    label = label,
    form = form,
    is_reference = form == 'scope',
    node = node,
    row = row,
    col = col,
    end_row = end_row,
  }
end

M.read_tag = read

---Every footnote tag of a buffer, in order
---@param bufnr? integer
---@return FeyFootnoteTag[]
function M.scan(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local parser = vim.treesitter.get_parser(bufnr, 'fey')
  local tree = parser:parse()[1]
  local out = {}
  for _, node in get_query():iter_captures(tree:root(), bufnr) do
    local tag = not node:has_error() and read(bufnr, node) or nil
    if tag then out[#out + 1] = tag end
  end
  return out
end

---@param label string
---@param is_reference boolean
---@param bufnr? integer
---@return FeyFootnoteTag|nil first the first tag of that kind with that label
function M.find(label, is_reference, bufnr)
  for _, tag in ipairs(M.scan(bufnr)) do
    if tag.label == label and tag.is_reference == is_reference then return tag end
  end
end

---The footnote tag under the cursor: a reference or a line tag definition when the cursor is on the tag, a pair
---or block definition when it is on its opening line (a pair also on its closing line)
---@param bufnr? integer
---@return FeyFootnoteTag|nil
function M.at_cursor(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  row = row - 1
  local best
  for _, tag in ipairs(M.scan(bufnr)) do
    if tag.form == 'scope' or tag.form == 'line' then
      local _, _, er, ec = tag.node:range()
      if row == tag.row and col >= tag.col and (er > tag.row or col < ec) then best = tag end
    elseif tag.form == 'block' then
      if row == tag.row then best = tag end
    elseif row == tag.row or row == tag.end_row then
      best = tag
    end
  end
  return best
end

---The smallest number no footnote of the buffer uses
---@param bufnr? integer
---@return string
function M.next_label(bufnr)
  local used = {}
  for _, tag in ipairs(M.scan(bufnr)) do
    local n = tonumber(tag.label)
    if n then used[n] = true end
  end
  local n = 1
  while used[n] do n = n + 1 end
  return tostring(n)
end

---The lines of a new definition in a form, and where the cursor goes in them (line, column 0-based)
---@param label string
---@param form 'pair'|'line'|'block'
---@return string[] lines
---@return integer cursor_line 1-based, in the lines
---@return integer cursor_col
local function definition_lines(label, form)
  local name = config.fey_footnote_tag_name
  if form == 'line' then
    local head = ('#[ %s, %s ] '):format(name, label)
    return { head .. '#' }, 1, #head
  elseif form == 'block' then
    return { ('[ %s, %s ]#'):format(name, label), '    ' }, 2, 4
  end
  return { ('[ %s, %s #]'):format(name, label), '', ('[# %s ]'):format(name) }, 2, 0
end

---Write a definition under the heading `Footnotes`, or at the end of the file, in the form of
---`fey_footnote_definition_form` (`pair`, `line` or `block`), and put the cursor where the text goes
---@param label string
---@param bufnr? integer
---@param insert? boolean start insert mode in the text
function M.create_definition(label, bufnr, insert)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local form = config.fey_footnote_definition_form or 'pair'
  local block, cursor_line, cursor_col = definition_lines(label, form)
  local file = require('fey').instance().files:get_current_file()
  local heading = file:find_heading_by_title('footnotes')
  local at
  local lead = false
  if heading then
    at = heading:get_append_line()
    local before = vim.api.nvim_buf_get_lines(bufnr, math.max(at - 1, 0), at, false)[1]
    lead = before ~= nil and before:match('%S') ~= nil
  else
    at = vim.api.nvim_buf_line_count(bufnr)
    local last = vim.api.nvim_buf_get_lines(bufnr, at - 1, at, false)[1]
    lead = last ~= nil and last:match('%S') ~= nil
  end
  if lead then
    table.insert(block, 1, '')
    cursor_line = cursor_line + 1
  end
  vim.api.nvim_buf_set_lines(bufnr, at, at, false, block)
  vim.api.nvim_win_set_cursor(0, { at + cursor_line, cursor_col })
  if insert then vim.cmd(cursor_col > 0 and 'startinsert!' or 'startinsert') end
end

---Jump to the definition of a reference; with none, offer to make one
---@param tag FeyFootnoteTag
function M.goto_definition(tag)
  local bufnr = vim.api.nvim_get_current_buf()
  local definition = M.find(tag.label, false, bufnr)
  if definition then
    vim.cmd([[normal! m']])
    if definition.form == 'line' then
      -- the text of a line tag follows its head
      local body
      for child in definition.node:iter_children() do
        if child:type() == 'body' then body = child end
      end
      local brow, bcol = (body or definition.node):start()
      return vim.api.nvim_win_set_cursor(0, { brow + 1, bcol })
    end
    -- into the text, under the opening line
    return vim.api.nvim_win_set_cursor(0, { math.min(definition.row + 2, definition.end_row + 1), 0 })
  end
  if vim.fn.confirm(('No definition of footnote "%s". Create one?'):format(tag.label), '&Yes\n&No') ~= 1 then return end
  vim.cmd([[normal! m']])
  M.create_definition(tag.label, bufnr, true)
end

---Jump from a definition to its first reference
---@param tag FeyFootnoteTag
function M.goto_reference(tag)
  local reference = M.find(tag.label, true)
  if not reference then
    return vim.notify(('fey: nothing refers to footnote "%s"'):format(tag.label), vim.log.levels.INFO)
  end
  vim.cmd([[normal! m']])
  vim.api.nvim_win_set_cursor(0, { reference.row + 1, reference.col })
end

---Put a reference at the cursor and make its definition, ready to be typed (the mapping `fey_insert_footnote`)
function M.insert()
  local bufnr = vim.api.nvim_get_current_buf()
  local label = M.next_label(bufnr)
  local text = ('{@ %s, %s @}'):format(config.fey_footnote_tag_name, label)
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  -- after the character under the cursor, like `a`
  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ''
  local at = line == '' and 0 or math.min(col + 1, #line)
  vim.api.nvim_buf_set_text(bufnr, row - 1, at, row - 1, at, { text })
  M.create_definition(label, bufnr, true)
end

---The handlers of the footnote tag, for the open-at-point mapping: a reference goes to its definition, a
---definition (in any form) back to the first reference
M.handlers = {
  scope_tag = function(tag) M.goto_definition(M.at_cursor(tag.bufnr) or { label = tag.values[1] }) end,
  line_tag = function(tag) M.goto_reference(M.at_cursor(tag.bufnr) or { label = tag.values[1] }) end,
  block_tag = function(tag) M.goto_reference(M.at_cursor(tag.bufnr) or { label = tag.values[1] }) end,
  pair_tag = function(tag) M.goto_reference(M.at_cursor(tag.bufnr) or { label = tag.values[1] }) end,
}

return M
