-- The document of `fey.export.model` as GitHub flavoured Markdown.
local M = {}

local function escape(s, cell)
  s = s:gsub('([\\`*_%[%]<>])', '\\%1')
  if cell then s = s:gsub('|', '\\|'):gsub('\n', ' ') end
  return s
end

local render_inlines

---@param items table[]
---@param cell? boolean
---@return string
render_inlines = function(items, cell)
  local out = {}
  for _, item in ipairs(items) do
    if item.t == 'text' then
      out[#out + 1] = escape(item.s, cell)
    elseif item.t == 'code' then
      local ticks = item.s:find('`', 1, true) and '``' or '`'
      out[#out + 1] = ticks .. item.s .. ticks
    elseif item.t == 'em' then
      local inner = render_inlines(item.children, cell)
      if item.kind == 'bold' then
        out[#out + 1] = '**' .. inner .. '**'
      elseif item.kind == 'italic' then
        out[#out + 1] = '*' .. inner .. '*'
      elseif item.kind == 'strike' then
        out[#out + 1] = '~~' .. inner .. '~~'
      else
        out[#out + 1] = '<u>' .. inner .. '</u>'
      end
    elseif item.t == 'link' then
      local inner = render_inlines(item.children, cell)
      out[#out + 1] = item.href and ('[%s](%s)'):format(inner, item.href:gsub('[%s()]', function(c) return ('%%%02X'):format(c:byte()) end)) or inner
    elseif item.t == 'fnref' then
      out[#out + 1] = ('[^%s]'):format(item.label)
    elseif item.t == 'math' then
      out[#out + 1] = '$' .. item.s .. '$'
    elseif item.t == 'wrap' then
      local body = render_inlines(item.children, cell)
      out[#out + 1] = require('fey.export.tags').render(item.spec, item.tag, body, 'markdown') or body
    elseif item.t == 'html' then
      -- embedded HTML, its content is Markdown again
      local attrs = {}
      for _, a in ipairs(item.attrs or {}) do
        attrs[#attrs + 1] = (' %s="%s"'):format(a.name, a.value:gsub('&', '&amp;'):gsub('"', '&quot;'):gsub('<', '&lt;'))
      end
      out[#out + 1] = ('<%s%s>%s</%s>'):format(item.tag, table.concat(attrs), render_inlines(item.children, cell), item.tag)
    end
  end
  local s = table.concat(out)
  if not cell then s = s:gsub('\n[ \t]*', '\n') end
  return s
end

local render_blocks

---@param block table
---@param indent string
---@param out string[]
local function render_list(block, indent, out)
  for i, item in ipairs(block.items) do
    local bullet = block.ordered and (i .. '. ') or '- '
    local box = item.checked == nil and '' or (item.checked and '[x] ' or '[ ] ')
    local pad = indent .. (' '):rep(#bullet)
    local sub = {}
    render_blocks(item.blocks, pad, sub, true)
    -- the first line of the first block goes after the bullet
    local first = true
    for _, line in ipairs(sub) do
      if first and line ~= '' then
        out[#out + 1] = indent .. bullet .. box .. line:sub(#pad + 1)
        first = false
      elseif not first or line ~= '' then
        out[#out + 1] = line
      end
    end
    if first then out[#out + 1] = indent .. bullet .. box end
  end
end

---@param blocks table[]
---@param indent string
---@param out string[]
---@param tight? boolean no blank line between the blocks (the contents of a list item)
render_blocks = function(blocks, indent, out, tight)
  for i, block in ipairs(blocks) do
    local t = block.t
    local start = #out
    if t == 'paragraph' then
      for _, line in ipairs(vim.split(render_inlines(block.inlines), '\n', { plain = true })) do
        -- a line that would start a list, a heading or a quote is text
        line = line:gsub('^(%s*)([%-%+#>])', '%1\\%2'):gsub('^(%s*%d+)([.)])(%s)', '%1\\%2%3')
        out[#out + 1] = indent .. line
      end
    elseif t == 'list' then
      render_list(block, indent, out)
    elseif t == 'table' and block.merged then
      -- Markdown has no merged cells: the table is embedded as HTML
      for _, line in ipairs(require('fey.export.html').merged_table(block)) do
        out[#out + 1] = indent .. line
      end
    elseif t == 'wrapblock' then
      local inner = {}
      render_blocks(block.blocks, indent, inner)
      local body = table.concat(inner, '\n')
      local tags = require('fey.export.tags')
      local value = tags.resolve(block.spec, block.tag.form, 'markdown')
      local text
      if type(value) == 'string' then
        -- the wrapper is HTML around Markdown: blank lines let the Markdown go on being Markdown
        text = tags.fill(value, '\n\n' .. body .. '\n\n'):gsub('\n\n\n+', '\n\n')
      else
        text = tags.render(block.spec, block.tag, body, 'markdown')
      end
      for _, line in ipairs(vim.split(text or body, '\n', { plain = true })) do
        out[#out + 1] = line == '' and '' or (indent .. line)
      end
    elseif t == 'htmlblock' then
      local attrs = {}
      for _, a in ipairs(block.attrs or {}) do
        attrs[#attrs + 1] = (' %s="%s"'):format(a.name, a.value:gsub('&', '&amp;'):gsub('"', '&quot;'):gsub('<', '&lt;'))
      end
      out[#out + 1] = ('%s<%s%s>'):format(indent, block.tag, table.concat(attrs))
      out[#out + 1] = ''
      render_blocks(block.blocks, indent, out)
      out[#out + 1] = ''
      out[#out + 1] = ('%s</%s>'):format(indent, block.tag)
    elseif t == 'table' then
      local header = block.header or (block.rows[1] and (function()
        local empty = {}
        for _ = 1, #block.rows[1] do
          empty[#empty + 1] = {}
        end
        return empty
      end)()) or {}
      local function row(cells)
        local texts = {}
        for _, c in ipairs(cells) do
          texts[#texts + 1] = render_inlines(c, true)
        end
        return indent .. '| ' .. table.concat(texts, ' | ') .. ' |'
      end
      out[#out + 1] = row(header)
      out[#out + 1] = indent .. '|' .. (' --- |'):rep(#header)
      for _, r in ipairs(block.rows) do
        out[#out + 1] = row(r)
      end
    elseif t == 'code' then
      local fence = block.text:find('```', 1, true) and '~~~' or '```'
      out[#out + 1] = indent .. fence .. (block.lang or '')
      for _, line in ipairs(vim.split(block.text, '\n', { plain = true })) do
        out[#out + 1] = line == '' and '' or (indent .. line)
      end
      out[#out + 1] = indent .. fence
    elseif t == 'math' then
      out[#out + 1] = indent .. '$$'
      for _, line in ipairs(vim.split(block.s, '\n', { plain = true })) do
        out[#out + 1] = indent .. vim.trim(line)
      end
      out[#out + 1] = indent .. '$$'
    elseif t == 'linkblock' then
      local inner = {}
      render_blocks(block.blocks, indent, inner)
      if block.href then
        -- the link is the whole block: each paragraph of it is wrapped
        for _, line in ipairs(inner) do
          if line:match('%S') and not line:match('^%s*[|%-%d`$~]') then
            out[#out + 1] = indent .. ('[%s](%s)'):format(vim.trim(line), block.href)
          else
            out[#out + 1] = line
          end
        end
      else
        vim.list_extend(out, inner)
      end
    end
    if #out > start and i < #blocks and not (tight and (t == 'paragraph' or t == 'list') and blocks[i + 1].t == 'list') then
      out[#out + 1] = ''
    end
  end
end

local function render_section(section, out)
  local title = render_inlines(section.title)
  if section.status then title = section.status .. ' ' .. title end
  out[#out + 1] = ('%s %s'):format(('#'):rep(math.min(section.level + (section.offset or 0), 6)), title)
  if #section.labels > 0 then
    out[#out + 1] = ''
    out[#out + 1] = table.concat(vim.tbl_map(function(l) return '`' .. l .. '`' end, section.labels), ' ')
  end
  if #section.blocks > 0 then
    out[#out + 1] = ''
    render_blocks(section.blocks, '', out)
  end
  for _, sub in ipairs(section.sections) do
    out[#out + 1] = ''
    render_section(sub, out)
  end
end

---@param doc table see `fey.export.model`
---@return string
function M.render(doc)
  local out = {}
  if doc.title then
    -- a front matter pandoc reads and GitHub shows as a table
    out[#out + 1] = '---'
    out[#out + 1] = 'title: ' .. vim.json.encode(doc.title)
    if doc.author then out[#out + 1] = 'author: ' .. vim.json.encode(doc.author) end
    out[#out + 1] = '---'
    out[#out + 1] = ''
  end
  local content = {}
  if #doc.blocks > 0 then
    render_blocks(doc.blocks, '', content)
    content[#content + 1] = ''
  end
  for i, section in ipairs(doc.sections) do
    render_section(section, content)
    if i < #doc.sections then content[#content + 1] = '' end
  end
  -- a scope tag above the first heading applies to the whole file
  for _, w in ipairs(doc.wrap or {}) do
    local tags = require('fey.export.tags')
    local value = tags.resolve(w.spec, w.tag.form, 'markdown')
    local body = table.concat(content, '\n')
    local text = type(value) == 'string' and tags.fill(value, '\n\n' .. body .. '\n\n'):gsub('\n\n\n+', '\n\n') or tags.render(w.spec, w.tag, body, 'markdown')
    if text then content = vim.split(text, '\n', { plain = true }) end
  end
  vim.list_extend(out, content)
  if #doc.footnote_order > 0 then
    out[#out + 1] = ''
    for _, label in ipairs(doc.footnote_order) do
      local blocks = doc.footnotes[label]
      if blocks then
        local sub = {}
        render_blocks(blocks, '    ', sub)
        local first = true
        for _, line in ipairs(sub) do
          if first then
            out[#out + 1] = ('[^%s]: %s'):format(label, vim.trim(line))
            first = false
          else
            out[#out + 1] = line
          end
        end
      end
    end
  end
  return table.concat(out, '\n') .. '\n'
end

return M
