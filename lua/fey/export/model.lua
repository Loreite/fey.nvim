-- The tree of a Fey text as a document an exporter can write: sections with blocks and inline items, no syntax. What the
-- exporters share is decided here:
--
--   * a `comment` tag hides what it comments (`fey.files.elements.tags.handlers.comment`); a file that is all commented has
--     nothing to export (`model.empty`)
--   * the tags of the machinery are left out (`status` and `labels` become the keyword and the labels of the heading; `prop`, the dates
--     of planning, `clock`, `logbook`, `table` data and the query tags that run are dropped)
--   * the result of a query, a feydb or a clock table is content, its links are links
--   * `math` is math, `fn` is a footnote, `link` and `section` are links, a date is its text, any other tag keeps what it holds
local config = require('fey.config')
local comment = require('fey.files.elements.tags.handlers.comment')
local inline = require('fey.export.inline')
local signature = require('fey.links.signature')

local M = {}

---@class FeyExportCtx
---@field src string
---@field extension string
---@field commented { from: integer, to: integer }[]
---@field footnotes table<string, table[]>
---@field footnote_order string[]
---@field ids table<string, boolean>

---@param ctx FeyExportCtx
---@param node TSNode
local function text(ctx, node) return vim.treesitter.get_node_text(node, ctx.src) end

---@param ctx FeyExportCtx
---@param node TSNode
---@return boolean
local function hidden(ctx, node)
  local _, _, from = node:start()
  local _, _, to = node:end_()
  for _, c in ipairs(ctx.commented) do
    if from >= c.from and to <= c.to then return true end
  end
  return false
end

local function head_of(node) return node:type() == 'pair_tag' and node:field('open')[1] or node end

local function tag_name(ctx, node)
  local name = head_of(node):field('name')[1]
  return name and text(ctx, name) or ''
end

---@param ctx FeyExportCtx
---@param node TSNode
---@return string[] values, table<string, string> keys
local function tag_head(ctx, node)
  local head = head_of(node)
  local values, keys = {}, {}
  for _, v in ipairs(head:field('value')) do
    values[#values + 1] = (vim.trim(text(ctx, v)):gsub('\\(.)', '%1'))
  end
  for _, kv in ipairs(head:field('key_value')) do
    local k, v = kv:field('key')[1], kv:field('value')[1]
    if k and v then keys[vim.trim(text(ctx, k))] = (vim.trim(text(ctx, v)):gsub('\\(.)', '%1')) end
  end
  return values, keys
end

local function body_of(node)
  local t = node:type()
  if t == 'pair_tag' or t == 'block_tag' then return node:field('body')[1] end
  if t == 'line_tag' then
    for child in node:iter_children() do
      if child:type() == 'body' then return child end
    end
  end
end

-- the kinds of tag names, from the configuration
local function kind_of(name)
  if name == config.fey_link_tag_name then return 'link' end
  if name == config.fey_section_tag_name then return 'section' end
  if name == config.fey_footnote_tag_name then return 'fn' end
  if name == config.fey_math_tag_name then return 'math' end
  if name == config.fey_comment_tag_name then return 'comment' end
  if name == config.fey_status_tag_name then return 'status' end
  if name == config.fey_labels_tag_name or vim.tbl_contains(config.vault.label_tags or {}, name) then return 'labels' end
  for _, n in ipairs({
    config.fey_property_tag_name, config.fey_scheduled_tag_name, config.fey_deadline_tag_name, config.fey_closed_tag_name,
    config.fey_clock_tag_name, config.fey_logbook_tag_name, config.fey_query_tag_name, config.fey_db_tag_name,
    config.fey_clocktable_tag_name, config.fey_nvim_config_tag_name, config.fey_plugin_tag_name, 'table', 'array', 'value',
  }) do
    if name == n then return 'machinery' end
  end
  if name == config.fey_date_tag_name then return 'date' end
end

-- tags named like an HTML element (`[ div; class: note ]#`, `#[ mark ] words #`, `[ details #]`) are that element in the export: embedded
-- HTML in Markdown, the element itself in HTML. The keys of the tag are its attributes. Elements that run code or load things are not
-- on the list, and neither are the event attributes. A name that something else has wins (`section` is a link, `table` data, a tag with an
-- export of its own), and the element is then written with a trailing underscore: `section_`. See `fey.export.tags`.
local exports = require('fey.export.tags')

---@param name string
---@return string|nil element the HTML element a tag name stands for (`section_` is `section`, see `fey.export.tags`)
local function html_element(name) return exports.html_element(name, kind_of) end

---The attributes of an HTML tag: the keys, without the ones that run code
---@param keys table<string, string>
---@return table[] list of { name, value } in a stable order
local function html_attrs(keys)
  local names = vim.tbl_keys(keys)
  table.sort(names)
  local out = {}
  for _, name in ipairs(names) do
    if name:match('^[%a][%w_:%-]*$') and not name:lower():match('^on') and name ~= 'srcdoc' then
      local value = keys[name]
      if not (value:lower():match('^%s*javascript:')) then out[#out + 1] = { name = name, value = value } end
    end
  end
  return out
end

-- inline ----------------------------------------------------------------------------------------------------------------

---Where a link leads in the exported file: a file of the notes becomes the exported file, a section an anchor
---@param ctx FeyExportCtx
---@param target string|nil
---@param sig string|nil
---@return string|nil
local function href(ctx, target, sig)
  local anchor = sig and ('#' .. M.anchor(sig)) or ''
  if not target or target == '' then return anchor ~= '' and anchor or nil end
  if target:match('^%a[%w+.-]*://') or target:match('^mailto:') then return target end
  if target:match('^%a[%w+.-]*:') then return nil end -- id:, a hollow, a scheme: nowhere in a file
  return (target:gsub('%.fey$', '.' .. ctx.extension):gsub('%.fey_archive$', '.' .. ctx.extension)) .. anchor
end

---The id of a heading
---@param sig string
---@return string
function M.anchor(sig)
  local key = signature.key(sig)
  return 'sec-' .. (key ~= '' and key:gsub('%.', '-') or 'x')
end

local convert_inlines

---Inline items of a tag
---@param ctx FeyExportCtx
---@param node TSNode
---@return table[]
local function inline_tag(ctx, node)
  local name = tag_name(ctx, node)
  local kind = kind_of(name)
  if kind == 'comment' or kind == 'machinery' or kind == 'status' or kind == 'labels' then return {} end
  local values, keys = tag_head(ctx, node)
  local body = body_of(node)
  local function body_items() return body and convert_inlines(ctx, body) or {} end
  if kind == 'link' or kind == 'section' then
    local target, sig = values[1], keys.section or keys.heading
    if kind == 'section' then target, sig = values[2] or keys.file, values[1] end
    local children = body and #body_items() > 0 and body_items() or nil
    if not children then
      local label = keys.desc
      if not label or label == '' then
        label = target and vim.fn.fnamemodify(target, ':t:r') or sig or ''
        if label == '' then label = sig or '' end
      end
      children = { { t = 'text', s = label } }
    end
    return { { t = 'link', href = href(ctx, target, sig), children = children } }
  elseif kind == 'fn' then
    local label = values[1]
    if not label then return {} end
    if body then
      -- a definition written as a line tag: collected, not shown
      ctx.footnotes[label] = ctx.footnotes[label] or { { t = 'paragraph', inlines = body_items() } }
      return {}
    end
    if not vim.tbl_contains(ctx.footnote_order, label) then ctx.footnote_order[#ctx.footnote_order + 1] = label end
    return { { t = 'fnref', label = label } }
  elseif kind == 'math' then
    local src = body and text(ctx, body) or values[1] or ''
    return { { t = 'math', s = vim.trim(src), display = false } }
  elseif kind == 'date' then
    return { { t = 'text', s = values[1] or '' } }
  end
  local spec = exports.lookup(name)
  if spec ~= nil then
    -- a tag with an export of its own: a line tag wraps its text; a scope tag is dealt with where its body is (`ctx.wrap`)
    if body then
      return { { t = 'wrap', spec = spec, tag = { name = name, form = node:type(), values = values, keys = keys }, children = body_items() } }
    end
    return {}
  end
  local element = body and html_element(name)
  if element then
    return { { t = 'html', tag = element, attrs = html_attrs(keys), children = body_items() } }
  end
  -- a tag of another kind keeps what it holds
  return body_items()
end

---Inline items of a node: its paragraph text with the tags turned into items
---@param ctx FeyExportCtx
---@param node TSNode a paragraph, a title, a contents or a body
---@return table[]
convert_inlines = function(ctx, node)
  local items = {}
  local _, _, from = node:start()
  local _, _, to = node:end_()
  local cursor = from
  local function plain(upto)
    if upto > cursor then
      local s = ctx.src:sub(cursor + 1, upto)
      vim.list_extend(items, inline.parse(s))
    end
  end
  local function walk(parent)
    for child in parent:iter_children() do
      local t = child:type()
      if t == 'scope_tag' or t == 'line_tag' or t == 'pair_tag' or t == 'block_tag' then
        local _, _, s = child:start()
        local _, _, e = child:end_()
        plain(s)
        if not hidden(ctx, child) then vim.list_extend(items, inline_tag(ctx, child)) end
        cursor = e
      elseif t == 'paragraph' or t == 'body' or t == 'contents' then
        walk(child)
      end
    end
  end
  walk(node)
  plain(to)
  -- trim the ends
  if items[1] and items[1].t == 'text' then items[1].s = items[1].s:gsub('^%s+', '') end
  local last = items[#items]
  if last and last.t == 'text' then last.s = last.s:gsub('%s+$', '') end
  return items
end

-- blocks ------------------------------------------------------------------------------------------------------------------

local convert_blocks

---Inline items of text that was cut out of a table cell: it is read again as the text of a paragraph
---@param ctx FeyExportCtx
---@param str string
---@return table[]
local function text_inlines(ctx, str)
  str = vim.trim(str)
  if str == '' then return {} end
  local sub = vim.tbl_extend('force', ctx, { src = str, commented = {} })
  local ok, parser = pcall(vim.treesitter.get_string_parser, str, 'fey')
  if ok then
    local root = parser:parse()[1]:root()
    local body = root:field('body')[1]
    local paragraph = body and body:named_child(0)
    if paragraph and paragraph:type() == 'paragraph' then return convert_inlines(sub, paragraph) end
  end
  return inline.parse(str)
end

---The table of merged cells: a grid of cells with spans, which only HTML can say
---@param ctx FeyExportCtx
---@param node TSNode
---@return table
local function convert_merged_table(ctx, node)
  local tbl = require('fey.files.elements.table').from_node(node, ctx.src)
  -- the header is what is above the first rule that has rows above it
  local header_rows, rows_seen = 0, 0
  for _, entry in ipairs(tbl.logical_grid) do
    if entry.type == 'hr' and rows_seen > 0 then
      header_rows = rows_seen
      break
    end
    if entry.cells then rows_seen = rows_seen + 1 end
  end
  local rows = {}
  for _, row in ipairs(tbl.rows) do
    local cells = {}
    for _, cell in ipairs(row.cells) do
      -- the cells that a row span covers are not written again
      if cell.rowspan ~= 0 then
        cells[#cells + 1] = {
          inlines = text_inlines(ctx, table.concat(cell.lines, '\n')),
          colspan = cell.colspan,
          rowspan = cell.rowspan,
        }
      end
    end
    rows[#rows + 1] = cells
  end
  return { t = 'table', merged = true, header_rows = header_rows, grid = rows, rows = {} }
end

---@param ctx FeyExportCtx
---@param node TSNode a table
local function convert_table(ctx, node)
  -- merged cells come out of the grid of the table with their spans
  local ok, merged = pcall(function()
    local tbl = require('fey.files.elements.table').from_node(node, ctx.src)
    for _, row in ipairs(tbl.rows) do
      for _, cell in ipairs(row.cells) do
        if cell.colspan > 1 or cell.rowspan ~= 1 then return true end
      end
    end
    return false
  end)
  if ok and merged then return convert_merged_table(ctx, node) end
  local rows, header = {}, nil
  local function row_of(row)
    local cells = {}
    for _, cell in ipairs(row:field('cell')) do
      local contents = cell:field('contents')[1]
      cells[#cells + 1] = contents and convert_inlines(ctx, contents) or {}
    end
    return cells
  end
  for child in node:iter_children() do
    local t = child:type()
    if t == 'row' then
      local cells = row_of(child)
      if child:id() == (node:field('crown')[1] and node:field('crown')[1]:id()) then
        header = cells
      else
        rows[#rows + 1] = cells
      end
    elseif t == 'row_block' then
      for r in child:iter_children() do
        if r:type() == 'row' then rows[#rows + 1] = row_of(r) end
      end
    end
  end
  return { t = 'table', header = header, rows = rows }
end

---@param ctx FeyExportCtx
---@param node TSNode a list
local function convert_list(ctx, node)
  local items, ordered = {}, false
  for _, item in ipairs(node:named_children()) do
    if item:type() == 'listitem' then
      local bullet = item:field('bullet')[1]
      local token = bullet and vim.trim(text(ctx, bullet)) or '-'
      if #items == 0 then ordered = token:match('^%d') ~= nil end
      local box = item:field('checkbox')[1]
      local checked
      if box then
        local mark = vim.trim(text(ctx, box)):sub(2, 2)
        checked = require('fey.files.elements.checkbox').class('[' .. mark .. ']') == 'done'
      end
      local blocks = {}
      for _, c in ipairs(item:field('contents')) do
        vim.list_extend(blocks, convert_blocks(ctx, { c }))
      end
      items[#items + 1] = { checked = checked, blocks = M.wrapped(ctx, item, blocks) }
    end
  end
  return { t = 'list', ordered = ordered, items = items }
end

---@param ctx FeyExportCtx
---@param node TSNode a block (fenced)
local function convert_fenced(ctx, node)
  local name = node:field('name')[1]
  local params = {}
  for _, p in ipairs(node:field('parameter')) do
    params[#params + 1] = text(ctx, p)
  end
  local lang = params[1] and params[1]:sub(1, 1) ~= ':' and params[1] or nil
  local contents = node:field('contents')[1]
  local lines = {}
  if contents then
    local cs, _, ce, cec = contents:range()
    local src_lines = vim.split(ctx.src, '\n', { plain = true })
    lines = vim.list_slice(src_lines, cs + 1, cec == 0 and ce or ce + 1)
  end
  lines = require('fey.babel.tangle').dedent(lines)
  return { t = 'code', lang = lang, kind = name and text(ctx, name):lower() or '', text = table.concat(lines, '\n') }
end

---Blocks of a tag at block level
---@param ctx FeyExportCtx
---@param node TSNode
---@return table[]
local function convert_tag_block(ctx, node)
  local name = tag_name(ctx, node)
  local kind = kind_of(name)
  local body = body_of(node)
  local function inner() return body and convert_blocks(ctx, body:named_children()) or {} end
  if kind == 'comment' or kind == 'machinery' or kind == 'status' or kind == 'labels' then return {} end
  if node:type() == 'scope_tag' then
    if exports.lookup(name) ~= nil then return {} end
    -- a scope tag on a line of its own: a link or a footnote reference or a date is a paragraph, the rest is metadata
    if kind == 'link' or kind == 'section' or kind == 'date' or kind == 'fn' then
      local items = inline_tag(ctx, node)
      return #items > 0 and { { t = 'paragraph', inlines = items } } or {}
    end
    return {}
  end
  local values = select(1, tag_head(ctx, node))
  if kind == 'fn' then
    local label = values[1]
    if label then ctx.footnotes[label] = inner() end
    return {}
  elseif kind == 'math' then
    return { { t = 'math', s = vim.trim(body and text(ctx, body) or ''), display = true } }
  elseif kind == 'link' or kind == 'section' then
    -- a block, a pair or a line tag: what it holds is the link
    local _, keys = tag_head(ctx, node)
    local target, sig = values[1], keys.section or keys.heading
    if kind == 'section' then target, sig = values[2] or keys.file, values[1] end
    return { { t = 'linkblock', href = href(ctx, target, sig), blocks = inner() } }
  end
  local _, keys = tag_head(ctx, node)
  local spec = exports.lookup(name)
  if spec ~= nil then
    return { { t = 'wrapblock', spec = spec, tag = { name = name, form = node:type(), values = values, keys = keys }, blocks = inner() } }
  end
  local element = html_element(name)
  if element then return { { t = 'htmlblock', tag = element, attrs = html_attrs(keys), blocks = inner() } } end
  return inner()
end

---Put blocks in the wrappers of the scope tags that apply to a node (the paragraph, the list, the list item, the text of a section)
---@param ctx FeyExportCtx
---@param node TSNode
---@param blocks table[]
---@return table[]
local function wrapped(ctx, node, blocks)
  local wrappers = ctx.wrap[node:id()]
  if not wrappers or #blocks == 0 then return blocks end
  for _, w in ipairs(wrappers) do
    blocks = { { t = 'wrapblock', spec = w.spec, tag = w.tag, blocks = blocks } }
  end
  return blocks
end
M.wrapped = wrapped

---@param ctx FeyExportCtx
---@param nodes TSNode[]
---@return table[]
convert_blocks = function(ctx, nodes)
  local blocks = {}
  for _, node in ipairs(nodes) do
    local t = node:type()
    local one = {}
    if hidden(ctx, node) then
      -- a comment
    elseif t == 'paragraph' then
      local items = convert_inlines(ctx, node)
      if #items > 0 then one[1] = { t = 'paragraph', inlines = items } end
    elseif t == 'list' then
      one[1] = convert_list(ctx, node)
    elseif t == 'table' then
      one[1] = convert_table(ctx, node)
    elseif t == 'block' then
      one[1] = convert_fenced(ctx, node)
    elseif t == 'scope_tag' or t == 'pair_tag' or t == 'block_tag' or t == 'line_tag' then
      one = convert_tag_block(ctx, node)
    end
    vim.list_extend(blocks, wrapped(ctx, node, one))
  end
  return blocks
end

-- sections ------------------------------------------------------------------------------------------------------------------

---@param ctx FeyExportCtx
---@param node TSNode a section
local function convert_section(ctx, node)
  local heading = node:field('heading')[1]
  local sig = heading and heading:field('signature')[1]
  local level = 0
  if sig then
    for _, c in ipairs(sig:named_children()) do
      if c:type() == 'segment' then level = level + 1 end
    end
  end
  local section = {
    level = math.max(level, 1),
    signature = sig and vim.trim(text(ctx, sig)) or '',
    title = {},
    labels = {},
    blocks = {},
    sections = {},
  }
  local title = heading and heading:field('title')[1]
  if title then
    section.title = convert_inlines(ctx, title)
    for child in title:iter_children() do
      if child:type() == 'scope_tag' and not hidden(ctx, child) then
        local kind = kind_of(tag_name(ctx, child))
        local values = select(1, tag_head(ctx, child))
        if kind == 'status' then
          section.status = values[1]
        elseif kind == 'labels' then
          vim.list_extend(section.labels, values)
        end
      end
    end
  end
  local id = M.anchor(section.signature)
  local n = 1
  local unique = id
  while ctx.ids[unique] do
    n = n + 1
    unique = id .. '-' .. n
  end
  ctx.ids[unique] = true
  section.id = unique
  local body = node:field('body')[1]
  if body then section.blocks = M.wrapped(ctx, body, convert_blocks(ctx, body:named_children())) end
  for _, sub in ipairs(node:field('subsection')) do
    section.sections[#section.sections + 1] = convert_section(ctx, sub)
  end
  return section
end

---The document of a text
---@param src string
---@param opts? { extension?: string } the extension the links to other notes end with
---@return table|nil doc nil when everything is commented
function M.parse(src, opts)
  opts = opts or {}
  local parser = vim.treesitter.get_string_parser(src, 'fey')
  local root = parser:parse()[1]:root()
  local query = vim.treesitter.query.get('fey', 'fey_tags')
  local ctx = { src = src, extension = opts.extension or 'md', commented = {}, footnotes = {}, footnote_order = {}, ids = {}, wrap = {} }
  for _, c in ipairs(comment.bodies(root, src, query, config.fey_comment_tag_name, true)) do
    ctx.commented[#ctx.commented + 1] = { from = c.from, to = c.to }
    local _, _, rs = root:start()
    local _, _, re = root:end_()
    if c.from <= rs and c.to >= re then return nil end
  end

  -- the scope tags that have an export wrap what they apply to
  local Tag = require('fey.files.elements.tags')
  for _, node in query:iter_captures(root, src) do
    if node:type() == 'scope_tag' and not hidden(ctx, node) then
      local name = tag_name(ctx, node)
      local spec = exports.lookup(name)
      local target = spec ~= nil and Tag.body_node(node)
      if target then
        local values, keys = tag_head(ctx, node)
        ctx.wrap[target:id()] = ctx.wrap[target:id()] or {}
        table.insert(ctx.wrap[target:id()], { spec = spec, tag = { name = name, form = 'scope_tag', values = values, keys = keys } })
      end
    end
  end

  local meta = require('fey.vault.extract').extract(src, {})
  local data = type(meta.data) == 'table' and not vim.islist(meta.data) and meta.data or {}
  local doc = {
    title = meta.title ~= '' and meta.title or nil,
    author = type(data.author) == 'string' and data.author or nil,
    data = data,
    blocks = {},
    sections = {},
    footnotes = ctx.footnotes,
  }
  local body = root:field('body')[1]
  if body then doc.blocks = convert_blocks(ctx, body:named_children()) end
  for _, sub in ipairs(root:field('subsection')) do
    doc.sections[#doc.sections + 1] = convert_section(ctx, sub)
  end
  doc.wrap = ctx.wrap[root:id()]
  doc.footnote_order = ctx.footnote_order
  -- the footnotes that are defined and never referenced still go at the end
  for label in pairs(ctx.footnotes) do
    if not vim.tbl_contains(doc.footnote_order, label) then doc.footnote_order[#doc.footnote_order + 1] = label end
  end
  return doc
end

return M
