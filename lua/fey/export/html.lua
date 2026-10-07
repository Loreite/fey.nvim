-- The document of `fey.export.model` as one HTML page.
local M = {}

local function esc(s) return (s:gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;'):gsub('"', '&quot;')) end

local render_inlines

local function attrs_text(attrs)
  local out = {}
  for _, a in ipairs(attrs or {}) do
    out[#out + 1] = (' %s="%s"'):format(a.name, esc(a.value))
  end
  return table.concat(out)
end

render_inlines = function(items)
  local out = {}
  for _, item in ipairs(items) do
    if item.t == 'text' then
      out[#out + 1] = esc(item.s)
    elseif item.t == 'code' then
      out[#out + 1] = '<code>' .. esc(item.s) .. '</code>'
    elseif item.t == 'em' then
      local tag = ({ bold = 'strong', italic = 'em', underline = 'u', strike = 's' })[item.kind] or 'span'
      out[#out + 1] = ('<%s>%s</%s>'):format(tag, render_inlines(item.children), tag)
    elseif item.t == 'link' then
      local inner = render_inlines(item.children)
      out[#out + 1] = item.href and ('<a href="%s">%s</a>'):format(esc(item.href), inner) or inner
    elseif item.t == 'fnref' then
      out[#out + 1] = ('<sup><a href="#fn-%s" id="fnref-%s">%s</a></sup>'):format(esc(item.label), esc(item.label), esc(item.label))
    elseif item.t == 'math' then
      out[#out + 1] = '<span class="math inline">\\(' .. esc(item.s) .. '\\)</span>'
    elseif item.t == 'html' then
      out[#out + 1] = ('<%s%s>%s</%s>'):format(item.tag, attrs_text(item.attrs), render_inlines(item.children), item.tag)
    elseif item.t == 'wrap' then
      local body = render_inlines(item.children)
      out[#out + 1] = require('fey.export.tags').render(item.spec, item.tag, body, 'html') or body
    end
  end
  return table.concat(out):gsub('\n', ' ')
end

local render_blocks

---The HTML table of a table with merged cells
---@param block table
---@return string[]
function M.merged_table(block)
  local out = { '<table>' }
  local function row(cells, tag)
    local tds = {}
    for _, c in ipairs(cells) do
      local span = (c.colspan > 1 and (' colspan="%d"'):format(c.colspan) or '') .. (c.rowspan > 1 and (' rowspan="%d"'):format(c.rowspan) or '')
      tds[#tds + 1] = ('<%s%s>%s</%s>'):format(tag, span, render_inlines(c.inlines), tag)
    end
    return '<tr>' .. table.concat(tds) .. '</tr>'
  end
  if block.header_rows > 0 then
    out[#out + 1] = '<thead>'
    for i = 1, block.header_rows do
      out[#out + 1] = row(block.grid[i], 'th')
    end
    out[#out + 1] = '</thead>'
  end
  out[#out + 1] = '<tbody>'
  for i = block.header_rows + 1, #block.grid do
    out[#out + 1] = row(block.grid[i], 'td')
  end
  out[#out + 1] = '</tbody>'
  out[#out + 1] = '</table>'
  return out
end

---The HTML of inline items (for the renderers that embed HTML)
M.inlines = function(items) return render_inlines(items) end

render_blocks = function(blocks, out)
  for _, block in ipairs(blocks) do
    local t = block.t
    if t == 'paragraph' then
      out[#out + 1] = '<p>' .. render_inlines(block.inlines) .. '</p>'
    elseif t == 'list' then
      local tag = block.ordered and 'ol' or 'ul'
      out[#out + 1] = '<' .. tag .. '>'
      for _, item in ipairs(block.items) do
        local box = item.checked == nil and '' or ('<input type="checkbox" disabled%s> '):format(item.checked and ' checked' or '')
        local inner = {}
        render_blocks(item.blocks, inner)
        -- the text of the first paragraph sits in the item itself
        local first = inner[1] and inner[1]:match('^<p>(.*)</p>$')
        if first then inner[1] = first end
        out[#out + 1] = '<li>' .. box .. table.concat(inner, '\n') .. '</li>'
      end
      out[#out + 1] = '</' .. tag .. '>'
    elseif t == 'table' and block.merged then
      vim.list_extend(out, M.merged_table(block))
    elseif t == 'wrapblock' then
      local inner = {}
      render_blocks(block.blocks, inner)
      local body = table.concat(inner, '\n')
      local text = require('fey.export.tags').render(block.spec, block.tag, body, 'html') or body
      vim.list_extend(out, vim.split(text, '\n', { plain = true }))
    elseif t == 'htmlblock' then
      out[#out + 1] = ('<%s%s>'):format(block.tag, attrs_text(block.attrs))
      render_blocks(block.blocks, out)
      out[#out + 1] = ('</%s>'):format(block.tag)
    elseif t == 'table' then
      out[#out + 1] = '<table>'
      local function row(cells, cell_tag)
        local tds = {}
        for _, c in ipairs(cells) do
          tds[#tds + 1] = ('<%s>%s</%s>'):format(cell_tag, render_inlines(c), cell_tag)
        end
        return '<tr>' .. table.concat(tds) .. '</tr>'
      end
      if block.header then out[#out + 1] = '<thead>' .. row(block.header, 'th') .. '</thead>' end
      out[#out + 1] = '<tbody>'
      for _, r in ipairs(block.rows) do
        out[#out + 1] = row(r, 'td')
      end
      out[#out + 1] = '</tbody></table>'
    elseif t == 'code' then
      out[#out + 1] = ('<pre><code%s>%s</code></pre>'):format(block.lang and (' class="language-' .. esc(block.lang) .. '"') or '', esc(block.text))
    elseif t == 'math' then
      out[#out + 1] = '<div class="math display">\\[' .. esc(block.s) .. '\\]</div>'
    elseif t == 'linkblock' then
      local inner = {}
      render_blocks(block.blocks, inner)
      if block.href then
        out[#out + 1] = ('<a class="linkblock" href="%s">'):format(esc(block.href))
        vim.list_extend(out, inner)
        out[#out + 1] = '</a>'
      else
        vim.list_extend(out, inner)
      end
    end
  end
end

local function render_section(section, out)
  local title = render_inlines(section.title)
  if section.status then title = ('<span class="status">%s</span> %s'):format(esc(section.status), title) end
  local level = math.min(section.level, 6)
  out[#out + 1] = ('<section id="%s">'):format(section.id)
  out[#out + 1] = ('<h%d>%s</h%d>'):format(level, title, level)
  if #section.labels > 0 then
    out[#out + 1] = '<p class="labels">'
      .. table.concat(vim.tbl_map(function(l) return '<span class="label">' .. esc(l) .. '</span>' end, section.labels), ' ')
      .. '</p>'
  end
  render_blocks(section.blocks, out)
  for _, sub in ipairs(section.sections) do
    render_section(sub, out)
  end
  out[#out + 1] = '</section>'
end

local STYLE = [[
body { max-width: 46rem; margin: 2rem auto; padding: 0 1rem; font-family: system-ui, sans-serif; line-height: 1.55; }
pre { background: #f4f4f4; padding: .75rem; overflow-x: auto; }
table { border-collapse: collapse; } th, td { border: 1px solid #ccc; padding: .25rem .6rem; }
.status { font-weight: bold; color: #b00; } .label { background: #eee; border-radius: 3px; padding: 0 .3rem; font-size: .85em; }
.footnotes { font-size: .9em; } a.linkblock { display: block; color: inherit; text-decoration: none; }
@media (prefers-color-scheme: dark) { body { background: #1b1b1b; color: #ddd; } pre { background: #262626; } th, td { border-color: #444; } }
]]

---@param doc table see `fey.export.model`
---@return string
function M.render(doc)
  local out = {
    '<!doctype html>',
    '<html>',
    '<head>',
    '<meta charset="utf-8">',
    '<meta name="viewport" content="width=device-width, initial-scale=1">',
    '<title>' .. esc(doc.title or 'Notes') .. '</title>',
    '<style>' .. STYLE .. '</style>',
    '</head>',
    '<body>',
  }
  if doc.title then out[#out + 1] = '<h1 class="title">' .. esc(doc.title) .. '</h1>' end
  if doc.author then out[#out + 1] = '<p class="author">' .. esc(doc.author) .. '</p>' end
  local content = {}
  render_blocks(doc.blocks, content)
  for _, section in ipairs(doc.sections) do
    render_section(section, content)
  end
  -- a scope tag above the first heading applies to the whole file
  for _, w in ipairs(doc.wrap or {}) do
    local text = require('fey.export.tags').render(w.spec, w.tag, table.concat(content, '\n'), 'html')
    if text then content = vim.split(text, '\n', { plain = true }) end
  end
  vim.list_extend(out, content)
  if #doc.footnote_order > 0 then
    out[#out + 1] = '<ol class="footnotes">'
    for _, label in ipairs(doc.footnote_order) do
      local blocks = doc.footnotes[label]
      if blocks then
        local inner = {}
        render_blocks(blocks, inner)
        out[#out + 1] = ('<li id="fn-%s">%s <a href="#fnref-%s">↩</a></li>'):format(esc(label), table.concat(inner, ' '), esc(label))
      end
    end
    out[#out + 1] = '</ol>'
  end
  out[#out + 1] = '</body>'
  out[#out + 1] = '</html>'
  return table.concat(out, '\n') .. '\n'
end

return M
