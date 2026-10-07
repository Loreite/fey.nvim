-- Turn a query result into Fey source: a table (TABLE queries) or a list (LIST and TASK queries).
local V = require('fey.query.values')
local ops = require('fey.query.ops')

local M = {}

---@class FeyQueryRenderOpts
---@field link_tag? string tag name used for links. Default 'link'
---@field sigil? string tag token used for links. Default '@'
---@field hollow_id? string id of the hollow the result is written in: links to files of other hollows name their hollow

---Escape text for a tag head value (`,` `;` and `\` are the head's delimiters)
---@param s string
local function head_text(s)
  return (s:gsub('\\', '\\\\'):gsub(',', '\\,'):gsub(';', '\\;'):gsub('[\r\n]+', ' '))
end

---A link as a Fey scope tag: `{@ link, path; desc: Title; section: I.A. @}`
---@param link table
---@param opts FeyQueryRenderOpts
local function link_text(link, opts)
  local sigil = opts.sigil or '@'
  local path = link.path
  -- a file of another hollow is written with the hollow: court:notes/a.fey
  if link.hollow and opts.hollow_id and link.hollow ~= opts.hollow_id then path = link.hollow .. '/' .. path end
  local parts = { opts.link_tag or 'link', ', ', head_text(path) }
  if link.display and link.display ~= '' and link.display ~= link.path then
    parts[#parts + 1] = '; desc: ' .. head_text(link.display)
  end
  if link.subpath then parts[#parts + 1] = '; section: ' .. head_text(link.subpath) end
  return ('{%s %s %s}'):format(sigil, table.concat(parts), sigil)
end

---@param v any
---@param opts FeyQueryRenderOpts
---@return string
local function value_text(v, opts)
  local t = V.typeof(v)
  if t == 'null' then return '-' end
  if t == 'link' then return link_text(v, opts) end
  if t == 'array' then
    local parts = {}
    for i, item in ipairs(v) do
      parts[i] = value_text(item, opts)
    end
    return #parts == 0 and '-' or table.concat(parts, ', ')
  end
  if t == 'object' then
    local parts = {}
    for _, k in ipairs(V.keys(v)) do
      parts[#parts + 1] = k .. ': ' .. value_text(v[k], opts)
    end
    return '{ ' .. table.concat(parts, ', ') .. ' }'
  end
  return ((ops.tostring(v):gsub('[\r\n]+', ' ')))
end

---@param s string
local function width(s) return vim.fn.strdisplaywidth(s) end

---A cell must not contain the cell separator
---@param s string
local function cell_text(s) return (s:gsub('|', '\\|')) end

---@param result FeyQueryResult
---@param opts FeyQueryRenderOpts
---@return string[]
local function render_table(result, opts)
  local header, body = {}, {}
  for i, h in ipairs(result.headers) do
    header[i] = cell_text(h)
  end
  for r, row in ipairs(result.rows) do
    body[r] = {}
    for i = 1, #result.headers do
      body[r][i] = cell_text(value_text(row[i], opts))
    end
  end

  local widths = {}
  for i, h in ipairs(header) do
    widths[i] = width(h)
  end
  for _, row in ipairs(body) do
    for i, c in ipairs(row) do
      widths[i] = math.max(widths[i], width(c))
    end
  end

  local function line(cells)
    local out = {}
    for i, c in ipairs(cells) do
      out[i] = ' ' .. c .. (' '):rep(widths[i] - width(c)) .. ' '
    end
    return '|' .. table.concat(out, '|') .. '|'
  end

  local lines = { line(header) }
  local sep = {}
  for i, w in ipairs(widths) do
    sep[i] = ('='):rep(w + 2)
  end
  lines[2] = '+' .. table.concat(sep, '+') .. '+'
  for _, row in ipairs(body) do
    lines[#lines + 1] = line(row)
  end
  return lines
end

---@param items table[]
---@param indent string
---@param opts FeyQueryRenderOpts
---@param out string[]
local function render_items(items, indent, opts, out)
  for _, item in ipairs(items) do
    local text
    if item.task ~= nil then
      -- a task: its keyword, a link to its heading and its priority
      local state, priority = ops.get(item.task, 'state'), ops.get(item.task, 'priority')
      local parts = {}
      if state ~= V.NULL then parts[#parts + 1] = ops.tostring(state) end
      parts[#parts + 1] = value_text(ops.get(item.task, 'link'), opts)
      if priority ~= V.NULL then parts[#parts + 1] = '(' .. ops.tostring(priority) .. ')' end
      text = table.concat(parts, ' ')
    elseif item.id ~= nil and item.value ~= nil then
      text = value_text(item.id, opts) .. ': ' .. value_text(item.value, opts)
    elseif item.id ~= nil then
      text = value_text(item.id, opts)
    else
      text = value_text(item.value, opts)
    end
    out[#out + 1] = indent .. '-  ' .. text
    if item.children then render_items(item.children, indent .. '    ', opts, out) end
  end
end

---Lines of Fey source for a result
---@param result FeyQueryResult
---@param opts? FeyQueryRenderOpts
---@return string[]
function M.lines(result, opts)
  opts = opts or {}
  if result.count == 0 then return { ('No results to show for %s query.'):format(result.type) } end
  if result.type == 'table' then return render_table(result, opts) end
  local out = {}
  render_items(result.items, '', opts, out)
  return out
end

M.value_text = value_text

return M
