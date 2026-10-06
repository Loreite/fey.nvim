-- Text helpers for the database view: display width aware padding, truncation
-- and wrapping, and the text of cell values.
local V = require('fey.query.values')
local ops = require('fey.query.ops')

local M = {}

local dw = vim.fn.strdisplaywidth
M.width = dw

---@param s string
---@return string[] chars
local function chars(s) return vim.fn.split(s, '\\zs') end

---Cut to a display width, ending in `…` when something was cut
---@param s string
---@param w integer
---@return string
function M.truncate(s, w)
  if w <= 0 then return '' end
  if dw(s) <= w then return s end
  local out, used = {}, 0
  for _, ch in ipairs(chars(s)) do
    local cw = dw(ch)
    if used + cw > w - 1 then break end
    out[#out + 1] = ch
    used = used + cw
  end
  return table.concat(out) .. '…'
end

---@param s string
---@param w integer
---@param align? 'left'|'right'
---@return string
function M.pad(s, w, align)
  local gap = w - dw(s)
  if gap <= 0 then return s end
  if align == 'right' then return (' '):rep(gap) .. s end
  return s .. (' '):rep(gap)
end

---Break text into lines no wider than `w`, at spaces when possible
---@param s string
---@param w integer
---@return string[]
function M.wrap(s, w)
  if w <= 0 then return { '' } end
  local lines = {}
  local line, used = {}, 0
  local function flush()
    lines[#lines + 1] = table.concat(line)
    line, used = {}, 0
  end
  for word in s:gmatch('%S+%s*') do
    local ww = dw(word)
    if used + dw((word:gsub('%s+$', ''))) > w and used > 0 then flush() end
    if ww > w then
      -- a word wider than the column: hard break
      for _, ch in ipairs(chars(word)) do
        local cw = dw(ch)
        if used + cw > w then flush() end
        line[#line + 1] = ch
        used = used + cw
      end
    else
      line[#line + 1] = word
      used = used + ww
    end
  end
  if #line > 0 or #lines == 0 then flush() end
  for i, l in ipairs(lines) do
    lines[i] = (l:gsub('%s+$', ''))
  end
  return lines
end

---Short text of one value (lists are handled by `cell_items`)
---@param v any
---@return string
function M.scalar_text(v)
  local t = V.typeof(v)
  if t == 'null' then return '' end
  if t == 'link' then return v.display or v.path end
  if t == 'string' then return (v:gsub('\r', '')) end
  if t == 'object' then return ops.tostring(v) end
  return ops.tostring(v)
end

---The text lines of a cell: one per list item or text line
---@param v any
---@return string[]
function M.cell_items(v)
  if V.is_null(v) then return { '' } end
  if V.is_list(v) then
    if #v == 0 then return { '' } end
    local out = {}
    for _, item in ipairs(v) do
      out[#out + 1] = (M.scalar_text(item):gsub('\n', ' '))
    end
    return out
  end
  return vim.split(M.scalar_text(v), '\n', { plain = true })
end

---Lines of a cell for a column of width `w` and at most `max_lines` lines
---@param v any
---@param w integer
---@param max_lines integer
---@return string[]
function M.cell_lines(v, w, max_lines)
  local items = M.cell_items(v)
  if max_lines <= 1 then
    local joined = table.concat(items, ', ')
    return { M.truncate(joined, w) }
  end
  local out = {}
  for _, item in ipairs(items) do
    for _, l in ipairs(M.wrap(item, w)) do
      out[#out + 1] = l
    end
  end
  if #out > max_lines then
    out = vim.list_slice(out, 1, max_lines)
    out[#out] = M.truncate(out[#out] .. '…', w)
  end
  return out
end

---Text that edits a value (the reverse of `source_edit.parse_input`)
---@param v any
---@return string
function M.edit_text(v)
  if V.is_null(v) then return '' end
  if V.is_list(v) then
    local parts = {}
    for i, item in ipairs(v) do
      parts[i] = M.scalar_text(item)
    end
    return table.concat(parts, ', ')
  end
  return M.scalar_text(v)
end

---@param v any
---@return string glyph for a type
function M.type_glyph(t)
  return ({ number = '#', date = '@', boolean = '?', list = '≡', link = '→', mixed = '~' })[t] or ' '
end

return M
