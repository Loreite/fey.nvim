-- Org into the document of `fey.import.writer`, by walking the tree of the `org` tree-sitter parser (milisims' tree-sitter-org, the one the
-- orgmode plugin installs). The tree knows headings, tags, planning, properties, drawers, lists, tables, blocks, links, timestamps and footnotes.
-- It does not read the emphasis markers (`*bold*`, `/italic/`, `=verbatim=`), so those are matched in the text between the nodes, with the same
-- rules the exporter uses for Fey's own markers (`fey.export.inline`).
local inline = require('fey.export.inline')

local M = {}

local KINDS = { ['*'] = 'bold', ['/'] = 'italic', ['_'] = 'underline', ['+'] = 'strike', ['='] = 'code', ['~'] = 'code' }

local function node_text(ctx, node) return vim.treesitter.get_node_text(node, ctx.src) end

local function span(node)
  local _, _, from = node:start()
  local _, _, to = node:end_()
  return from, to
end

---Where the parser is: the runtime path, or a file named by `FEY_ORG_PARSER` / the option, or the folders the orgmode plugin and nvim-treesitter use
---@param path? string
---@return boolean ok
---@return string|nil err
function M.available(path)
  local function loaded(file)
    local ok, res = pcall(vim.treesitter.language.add, 'org', file and { path = file } or nil)
    return ok and res and true or false
  end
  if loaded() then return true end
  local candidates = { path, vim.env.FEY_ORG_PARSER }
  local data = vim.fn.stdpath('data')
  for _, pattern in ipairs({ '/lazy/*/parser/org.so', '/site/parser/org.so', '/lazy/*/parser/org.dll', '/site/parser/org.dll' }) do
    vim.list_extend(candidates, vim.fn.glob(data .. pattern, false, true))
  end
  for _, file in ipairs(candidates) do
    if file and file ~= '' and vim.uv.fs_stat(file) and loaded(file) then return true end
  end
  return false,
    'the tree-sitter parser for org is not installed: install it (`:TSInstall org`) or set FEY_ORG_PARSER to the org.so file'
end

-- inline ----------------------------------------------------------------------------------------------------------------------

---Emphasis in a run of plain text
---@param s string
---@return table[]
local function emphasis(s)
  if s == '' then return {} end
  return inline.parse(s, { kinds = KINDS, escapes = false })
end

---A timestamp node as the text of a `date` tag: the inside of the brackets, and whether it is active
---@return string value
---@return boolean active
local function timestamp(ctx, node)
  local raw = node_text(ctx, node)
  local active = raw:sub(1, 1) == '<'
  return (vim.trim(raw:gsub('[<>%[%]]', ''):gsub('%s+', ' '))), active
end

local function target_of(ctx, url)
  url = vim.trim(url)
  if url:match('^[*#]') then return nil end
  local path = url:gsub('^file:', ''):gsub('::.*$', '')
  if
    url:match('^file:')
    or url:match('^%.%.?/')
    or url:match('^/')
    or (not url:match('^%a[%w+.-]*:') and url:match('%.org$'))
  then
    if ctx.opts.link_extension ~= false then path = path:gsub('%.org$', '.fey'):gsub('%.org_archive$', '.fey_archive') end
    return path
  end
  return url
end

local function descr(ctx, node)
  if not node then return {} end
  return emphasis(node_text(ctx, node))
end

---Inline items of the children of a node, from a byte on
---@param ctx table
---@param node TSNode a paragraph, a description or a headline item
---@param from? integer
---@param to? integer
---@return table[]
local function inlines(ctx, node, from, to)
  local nf, nt = span(node)
  from, to = from or nf, to or nt
  local items, pos, buf = {}, from, {}
  local function flush()
    if #buf > 0 then
      vim.list_extend(items, emphasis(table.concat(buf)))
      buf = {}
    end
  end
  for child in node:iter_children() do
    local cf, ct = span(child)
    if cf >= from and ct <= to then
      if cf > pos then buf[#buf + 1] = ctx.src:sub(pos + 1, cf) end
      pos = ct
      local t = child:type()
      if t == 'timestamp' then
        flush()
        local value, active = timestamp(ctx, child)
        items[#items + 1] = { t = 'date', value = value, active = active }
      elseif t == 'link' or t == 'link_desc' then
        flush()
        local url = child:field('url')[1]
        local desc = child:field('desc')[1]
        local href = url and target_of(ctx, node_text(ctx, url))
        local children = descr(ctx, desc)
        if not href then
          ctx.dropped.internal = true
          vim.list_extend(items, #children > 0 and children or { { t = 'text', s = url and node_text(ctx, url) or '' } })
        else
          items[#items + 1] = { t = 'link', href = href, children = children }
        end
      elseif t == 'fnref' then
        flush()
        local label = child:field('label')[1]
        items[#items + 1] = { t = 'fnref', label = label and node_text(ctx, label) or '' }
      else
        buf[#buf + 1] = ctx.src:sub(cf + 1, ct)
      end
    end
  end
  if to > pos then buf[#buf + 1] = ctx.src:sub(pos + 1, to) end
  flush()
  local first, last = items[1], items[#items]
  if first and first.t == 'text' then first.s = first.s:gsub('^%s+', '') end
  if last and last.t == 'text' then last.s = last.s:gsub('%s+$', '') end
  return items
end

-- blocks ------------------------------------------------------------------------------------------------------------------

local blocks_of

---@param ctx table
---@param text string lines of a block, the common indentation taken off
local function dedent(text)
  local lines = vim.split(text, '\n', { plain = true })
  local indent
  for _, l in ipairs(lines) do
    if l:match('%S') then
      local lead = #l:match('^%s*')
      indent = indent and math.min(indent, lead) or lead
    end
  end
  for i, l in ipairs(lines) do
    lines[i] = l:sub((indent or 0) + 1):gsub('^,([*#])', '%1')
  end
  return table.concat(lines, '\n')
end

---Blocks of a text, by reading it as a document of its own (the contents of a quote, of a drawer)
---@param ctx table
---@param text string
---@return table[]
local function blocks_of_text(ctx, text)
  if not text:match('%S') then return {} end
  local src = dedent(text) .. '\n'
  local parser = vim.treesitter.get_string_parser(src, 'org')
  local root = parser:parse()[1]:root()
  local sub = vim.tbl_extend('force', ctx, { src = src })
  local body = root:field('body')[1]
  return body and blocks_of(sub, body) or {}
end

local function list(ctx, node)
  local items, ordered = {}, false
  for _, item in ipairs(node:named_children()) do
    if item:type() == 'listitem' then
      local bullet = item:field('bullet')[1]
      if bullet and node_text(ctx, bullet):match('^%d') or (bullet and node_text(ctx, bullet):match('^%a[.)]')) then
        ordered = true
      end
      local box
      local cb = item:field('checkbox')[1]
      if cb then
        local status = cb:field('status')[1]
        local mark = status and node_text(ctx, status) or ' '
        box = mark == 'X' and 'x' or mark == '-' and '/' or mark
      end
      local blocks = {}
      for _, c in ipairs(item:field('contents')) do
        vim.list_extend(blocks, blocks_of(ctx, { named_children = function() return { c } end }))
      end
      items[#items + 1] = { box = box, blocks = blocks }
    end
  end
  return { { t = 'list', ordered = ordered, items = items } }
end

local function block(ctx, node)
  local name = node:field('name')[1]
  name = name and node_text(ctx, name):lower() or ''
  local contents = node:field('contents')[1]
  local text = contents and node_text(ctx, contents):gsub('\n$', '') or ''
  local params = {}
  for _, p in ipairs(node:field('parameter')) do
    params[#params + 1] = node_text(ctx, p)
  end
  if name == 'src' or name == 'example' then
    local args = vim.list_slice(params, name == 'src' and 2 or 1)
    local named = node:field('directive')[1]
    local label
    if named then
      local n, v = named:field('name')[1], named:field('value')[1]
      if n and v and node_text(ctx, n):lower() == 'name' then label = vim.trim(node_text(ctx, v)) end
    end
    return {
      {
        t = 'code',
        kind = name,
        lang = name == 'src' and params[1] or nil,
        args = #args > 0 and table.concat(args, ' ') or nil,
        name = label,
        text = dedent(text),
      },
    }
  elseif name == 'quote' then
    return { { t = 'quote', blocks = blocks_of_text(ctx, text) } }
  elseif name == 'center' then
    return blocks_of_text(ctx, text)
  elseif name == 'verse' then
    return { { t = 'code', kind = 'example', text = dedent(text) } }
  elseif name == 'comment' then
    return { { t = 'comment', s = dedent(text) } }
  end
  ctx.dropped.block = true
  return { { t = 'comment', s = '#+begin_' .. name .. '\n' .. dedent(text) .. '\n#+end_' .. name } }
end

local function table_of(ctx, node)
  local header, rows, seen_hr = nil, {}, false
  for _, child in ipairs(node:named_children()) do
    local t = child:type()
    if t == 'row' then
      local cells = {}
      for _, cell in ipairs(child:named_children()) do
        if cell:type() == 'cell' then
          local contents = cell:field('contents')[1]
          cells[#cells + 1] = contents and inlines(ctx, contents) or {}
        end
      end
      rows[#rows + 1] = cells
    elseif t == 'hr' and not seen_hr then
      seen_hr = true
      if #rows >= 1 then header = table.remove(rows, 1) end
    end
  end
  return { { t = 'table', header = header, rows = rows } }
end

---@param ctx table
---@param node TSNode|table something with `named_children`
---@return table[]
blocks_of = function(ctx, node)
  local out = {}
  for _, c in ipairs(node:named_children()) do
    local t = c:type()
    local made
    if t == 'paragraph' then
      local items = inlines(ctx, c)
      if #items > 0 then made = { { t = 'paragraph', inlines = items } } end
    elseif t == 'list' then
      made = list(ctx, c)
    elseif t == 'block' then
      made = block(ctx, c)
    elseif t == 'table' then
      made = table_of(ctx, c)
    elseif t == 'comment' then
      made = { { t = 'comment', s = vim.trim(node_text(ctx, c):gsub('^%s*#%s?', '')) } }
    elseif t == 'fndef' then
      local label = c:field('label')[1]
      local desc = c:field('description')[1]
      made = {
        {
          t = 'fndef',
          label = label and node_text(ctx, label) or '',
          blocks = { { t = 'paragraph', inlines = desc and inlines(ctx, desc) or {} } },
        },
      }
    elseif t == 'drawer' then
      local name = c:field('name')[1]
      name = name and node_text(ctx, name) or 'drawer'
      local contents = c:field('contents')[1]
      ctx.drawers[#ctx.drawers + 1] = { name = name, text = contents and node_text(ctx, contents) or '' }
    elseif t == 'directive' then
      local name, value = c:field('name')[1], c:field('value')[1]
      local n = name and node_text(ctx, name):lower() or ''
      if n == 'tblfm' then ctx.dropped.tblfm = true end
    elseif t == 'latex_env' or t == 'horizontal_rule' then
      made = nil
    else
      local raw = vim.trim(node_text(ctx, c))
      if raw ~= '' then made = { { t = 'paragraph', inlines = emphasis(raw) } } end
    end
    if made then vim.list_extend(out, made) end
  end
  return out
end

-- sections ------------------------------------------------------------------------------------------------------------------

local function key_of(k) return (k:lower():gsub('[^%w_]', '_'):gsub('^(%d)', '_%1')) end

local function label_of(tag)
  if tag == 'ARCHIVE' then return 'archive' end
  return (tag:gsub('[^%w_@#%%-]', '-'))
end

---Drawers found in a body: the LOGBOOK becomes clock tags, the others pair tags
---@param ctx table
---@param section table
local function take_drawers(ctx, section)
  for _, drawer in ipairs(ctx.drawers) do
    local upper = drawer.name:upper()
    if upper == 'LOGBOOK' then
      local rest = {}
      for _, line in ipairs(vim.split(drawer.text, '\n', { plain = true })) do
        local a, b, dur = line:match('^%s*CLOCK:%s*(%b[])%-%-(%b[])%s*=>%s*(%S+)')
        if a then
          section.clocks[#section.clocks + 1] = { start = (a:gsub('[%[%]]', '')), ['end'] = (b:gsub('[%[%]]', '')), dur = dur }
        else
          local open = line:match('^%s*CLOCK:%s*(%b[])%s*$')
          if open then
            section.clocks[#section.clocks + 1] = { start = (open:gsub('[%[%]]', '')) }
          else
            rest[#rest + 1] = line
          end
        end
      end
      -- the clocks are written newest first; org lists them that way already, the writer reverses, so give them oldest first
      local flipped = {}
      for i = #section.clocks, 1, -1 do
        flipped[#flipped + 1] = section.clocks[i]
      end
      section.clocks = flipped
      section.logbook = blocks_of_text(ctx, table.concat(rest, '\n'))
    elseif upper == 'PROPERTIES' then
      -- not met here: the property drawer has a node of its own
    else
      section.drawers[#section.drawers + 1] = { name = key_of(drawer.name), blocks = blocks_of_text(ctx, drawer.text) }
    end
  end
  ctx.drawers = {}
end

local function todo_set(ctx)
  local set = {}
  for _, k in ipairs(ctx.todo) do
    if k ~= '|' then set[k] = true end
  end
  return set
end

local function section(ctx, node)
  local out = { title = {}, labels = {}, planning = {}, props = {}, clocks = {}, drawers = {}, blocks = {}, sections = {} }
  local headline = node:field('headline')[1]
  if headline then
    local item = headline:field('item')[1]
    if item then
      local from
      local keywords = todo_set(ctx)
      local seen_keyword, first = false, true
      for child in item:iter_children() do
        local t = child:type()
        local cf = span(child)
        if first and t == 'expr' and keywords[node_text(ctx, child)] then
          out.status = out.status or {}
          out.status[1] = node_text(ctx, child)
          seen_keyword = true
          from = nil
        elseif t == 'priority' then
          out.status = out.status or {}
          out.status[2] = node_text(ctx, child):match('%[#(.-)%]')
          from = nil
        elseif not from then
          from = cf
        end
        first = false
      end
      if from then out.title = inlines(ctx, item, from) end
    end
    local tags = headline:field('tags')[1]
    if tags then
      for _, tag in ipairs(tags:field('tag')) do
        out.labels[#out.labels + 1] = label_of(node_text(ctx, tag))
      end
    end
  end
  local plan = node:field('plan')[1]
  if plan then
    for _, entry in ipairs(plan:named_children()) do
      local name, ts = entry:field('name')[1], entry:field('timestamp')[1]
      if name and ts then
        local kind = node_text(ctx, name):lower()
        if kind == 'scheduled' or kind == 'deadline' or kind == 'closed' then
          local value, active = timestamp(ctx, ts)
          out.planning[#out.planning + 1] = { kind = kind, value = value, active = active }
        end
      end
    end
  end
  local props = node:field('property_drawer')[1]
  if props then
    for _, p in ipairs(props:named_children()) do
      if p:type() == 'property' then
        local n, v = p:field('name')[1], p:field('value')[1]
        if n then out.props[#out.props + 1] = { key_of(node_text(ctx, n)), v and vim.trim(node_text(ctx, v)) or '' } end
      end
    end
  end
  local body = node:field('body')[1]
  if body then
    ctx.drawers = {}
    out.blocks = blocks_of(ctx, body)
    take_drawers(ctx, out)
  end
  for _, sub in ipairs(node:field('subsection')) do
    out.sections[#out.sections + 1] = section(ctx, sub)
  end
  return out
end

---The document of an org text
---@param src string
---@param opts? { link_extension?: boolean, parser?: string }
---@return table|nil doc
---@return string|nil err
function M.parse(src, opts)
  opts = opts or {}
  local ok, err = M.available(opts.parser)
  if not ok then return nil, err end
  if src:sub(-1) ~= '\n' then src = src .. '\n' end
  local parser = vim.treesitter.get_string_parser(src, 'org')
  local root = parser:parse()[1]:root()
  local config = require('fey.config')
  local ctx = {
    src = src,
    opts = opts,
    dropped = {},
    drawers = {},
    todo = vim.deepcopy(config.fey_todo_keywords or { 'TODO', '|', 'DONE' }),
  }
  local doc = { data = {}, labels = {}, blocks = {}, sections = {}, warnings = {} }

  local body = root:field('body')[1]
  if body then
    for _, c in ipairs(body:named_children()) do
      if c:type() == 'directive' then
        local name, value = c:field('name')[1], c:field('value')[1]
        local n = name and node_text(ctx, name):lower() or ''
        local v = value and vim.trim(node_text(ctx, value)) or ''
        if n == 'todo' or n == 'seq_todo' or n == 'typ_todo' then
          ctx.todo = vim.split(v, '%s+', { trimempty = true })
          doc.data[#doc.data + 1] = { 'todo', v }
        elseif n == 'filetags' then
          for tag in v:gmatch('[^:%s]+') do
            doc.labels[#doc.labels + 1] = label_of(tag)
          end
        elseif n == 'tblfm' then
          ctx.dropped.tblfm = true
        elseif
          n ~= ''
          and not n:match('^name$')
          and not n:match('^results')
          and not n:match('^caption$')
          and not n:match('^attr_')
        then
          if v ~= '' then doc.data[#doc.data + 1] = { key_of(n), v } end
        end
      end
    end
    ctx.drawers = {}
    doc.blocks = blocks_of(ctx, body)
    -- a drawer above the first heading has nowhere to go but the text
    for _, drawer in ipairs(ctx.drawers) do
      if drawer.name:upper() == 'PROPERTIES' then
        for line in drawer.text:gmatch('[^\n]+') do
          local k, v = line:match('^%s*:([^:%s]+):%s*(.-)%s*$')
          if k then doc.data[#doc.data + 1] = { key_of(k), v } end
        end
      end
    end
  end
  for _, sub in ipairs(root:field('subsection')) do
    doc.sections[#doc.sections + 1] = section(ctx, sub)
  end

  local names = {
    internal = 'links to a heading or a custom id of the same file were kept as their text',
    block = 'blocks of other kinds were kept as comments',
    tblfm = 'table formulas (#+tblfm) were dropped',
  }
  for key, msg in pairs(names) do
    if ctx.dropped[key] then doc.warnings[#doc.warnings + 1] = msg end
  end
  table.sort(doc.warnings)
  return doc
end

return M
