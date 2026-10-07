-- Metadata extraction for the vault: Fey source text -> plain Lua tables.
--
-- Pure with respect to the editor (no buffers, no config, no database), so it
-- can run on any text. Everything is read from the tree-sitter-fey AST:
--
--   * the document data value (README VII): `table`/`array`/`value` data tags,
--     lists inside them (bullet anonymous text is the key) and headings as keys
--   * the heading outline
--   * every syntactic tag (`tags`), the cross-reference tags (`links`) and the
--     topical `labels`
--
-- Terminology: "tag" always means a Fey syntactic Tag. Topical categorisation
-- is called a "label" to avoid colliding with it.
local constants = require('fey.utils.constants')
local tag_region = require('fey.files.elements.tags.region')
local Date = require('fey.objects.date')

local M = {}

---@class FeyVaultExtractOpts
---@field label_tags? string[]  tag names whose values are labels. Default { 'label', 'labels' }
---@field link_tags? string[]   tag names that reference another file/section. Default { 'link', 'section' }
---@field date_tags? table<string, string> tag name -> kind (`date`, `scheduled`, `deadline`, `closed`) of the tags that hold a date. Default: those four names
---@field status_tag? string     name of the tag with the todo keyword and the priority. Default 'status'
---@field prop_tag? string       name of the tag with the properties of a heading. Default 'prop'
---@field todo_lookup? fun(data_todo: any): table<string, { type: string }> todo keywords by value; gets the `todo` key of the document data (nil when it has none). Default: TODO and DONE
---@field meta_tags? string[]   names of the tags that are heading metadata (a todo keyword, labels, ...). They
---                             are not part of the title of a heading: scope and line tags with one of these
---                             names are dropped from `title` and `path`. Default: see `DEFAULT_META_TAGS`

---@class FeyVaultHeading
---@field ord integer 1-based position in document order
---@field parent_ord? integer
---@field level integer
---@field signature string
---@field title string
---@field path string titles from the first heading down to this one, joined by '/'
---@field line integer 1-based
---@field end_line integer 1-based, inclusive (includes subsections)
---@field data? any data value of the section (only for sections without subsections)
---@field props table<string, string> the keys of the `prop` tags in its metadata region (names lower case)

---@class FeyVaultTag
---@field kind string scope|pair|line|block
---@field name string
---@field line integer
---@field heading_ord? integer
---@field region 'title'|'body'|'text'|'document' where the tag sits: part of the metadata region of its heading (title or body), elsewhere in a section, or above the first heading
---@field values string[]
---@field attrs table<string, string>
---@field order string[] key order of attrs

---@class FeyVaultLink
---@field kind string tag name (`link` or `section`)
---@field target string first value of the tag
---@field description? string
---@field attrs table<string, string>
---@field values string[]
---@field line integer
---@field heading_ord? integer

---@class FeyVaultLabel
---@field label string
---@field heading_ord? integer nil for a label of the file
---@field container string what holds the label: `title`, `body` or `text` (a label tag in a heading title, in the metadata region of a heading, or elsewhere in its text), `document` (a label tag above the first heading) or `data` (a `labels` key of a data tag or of the document data)
---@field line? integer 1-based line of the label

---@class FeyVaultDate
---@field heading_ord? integer
---@field line integer
---@field col integer
---@field kind string date, scheduled, deadline or closed
---@field active boolean
---@field start_ts integer epoch seconds
---@field start_time boolean the date has a time of day
---@field end_ts? integer end of a range, or of a time range on the same day
---@field end_time boolean the end has a time of day
---@field repeater? string `+1w`, `.+1d`, `++2m`
---@field warn? string the delay before it is due, `-3d`

---@class FeyVaultTask
---@field heading_ord integer
---@field line integer
---@field kind string heading
---@field state? string the todo keyword
---@field done boolean the keyword is a done keyword
---@field priority? string
---@field title string

---@class FeyVaultFileMeta
---@field title string
---@field data any document data value (nil is null)
---@field headings FeyVaultHeading[]
---@field tags FeyVaultTag[]
---@field links FeyVaultLink[]
---@field labels FeyVaultLabel[]
---@field dates FeyVaultDate[]
---@field tasks FeyVaultTask[]
---@field properties table<string, any> top level keys when the document data is a table
---@field errors string[]

local DATA_TAGS = { table = true, array = true, value = true }
local DEFAULT_META_TAGS = { 'label', 'labels', 'status', 'prop', 'scheduled', 'deadline', 'closed' }
local KIND = { scope_tag = 'scope', pair_tag = 'pair', line_tag = 'line', block_tag = 'block' }

local tag_query
local function get_tag_query()
  tag_query = tag_query or vim.treesitter.query.parse('fey', '[(scope_tag) (pair_tag) (line_tag) (block_tag)] @tag')
  return tag_query
end

---@param s string
local function trim(s) return (s:gsub('^%s+', ''):gsub('%s+$', '')) end

---Collapse whitespace runs (tag heads may span lines) and drop `\` escapes
---@param s string
local function tag_text(s) return trim((s:gsub('%s+', ' '):gsub('\\(.)', '%1'))) end

---JSON-style number: no leading zeros, no `_`, no other bases
---@param s string
local function is_number(s)
  local int, rest = s:gsub('^%-', ''):match('^(%d+)(.*)$')
  if not int or (#int > 1 and int:sub(1, 1) == '0') then return false end
  if rest:match('^%.%d+') then rest = rest:gsub('^%.%d+', '', 1) end
  if rest:match('^[eE][%+%-]?%d+') then rest = rest:gsub('^[eE][%+%-]?%d+', '', 1) end
  return rest == ''
end

---README VII.D
---@param s string
---@return string|number|boolean
local function scalar(s)
  s = trim(s)
  local quoted = s:match('^"(.*)"$') or s:match("^'(.*)'$")
  if quoted and #s >= 2 then return quoted end
  if s == 'true' then return true end
  if s == 'false' then return false end
  if is_number(s) then return tonumber(s) --[[@as number]] end
  return s
end

---@class FeyVaultCtx
---@field src string
---@field lines string[]
---@field errors string[]
---@field opts FeyVaultExtractOpts
---@field meta_set table<string, boolean> see `FeyVaultExtractOpts.meta_tags`

---@param ctx FeyVaultCtx
---@param node TSNode
---@param msg string
local function err(ctx, node, msg) table.insert(ctx.errors, ('line %d: %s'):format(node:start() + 1, msg)) end

---@param ctx FeyVaultCtx
---@param node TSNode
local function text(ctx, node) return vim.treesitter.get_node_text(node, ctx.src) end

---Last 1-indexed line covered by a node (a zero-width end at column 0 belongs to the line before)
---@param node TSNode
local function last_line(node)
  local _, _, end_row, end_col = node:range()
  if end_col == 0 and end_row > node:start() then end_row = end_row - 1 end
  return end_row + 1
end

-- Tags ----------------------------------------------------------------------

---@class FeyVaultParsedTag
---@field node TSNode
---@field kind string
---@field name string
---@field values string[]
---@field attrs table<string, any> raw text
---@field order string[]
---@field body? TSNode

---@param ctx FeyVaultCtx
---@param node TSNode scope_tag|pair_tag|line_tag|block_tag
---@return FeyVaultParsedTag|nil
local function parse_tag(ctx, node)
  local head = node:type() == 'pair_tag' and node:field('open')[1] or node
  local name = head and head:field('name')[1]
  if not name then return nil end

  local tag = {
    node = node,
    kind = KIND[node:type()],
    name = text(ctx, name),
    values = {},
    attrs = {},
    order = {},
  }
  for _, value in ipairs(head:field('value')) do
    table.insert(tag.values, tag_text(text(ctx, value)))
  end
  for _, kv in ipairs(head:field('key_value')) do
    local key, value = kv:field('key')[1], kv:field('value')[1]
    if key and value then
      local k = trim(text(ctx, key))
      if tag.attrs[k] == nil then table.insert(tag.order, k) end
      tag.attrs[k] = tag_text(text(ctx, value))
    end
  end
  if node:type() == 'pair_tag' or node:type() == 'block_tag' then tag.body = node:field('body')[1] end
  return tag
end

---Text of the title of a heading without its metadata tags (see `FeyVaultExtractOpts.meta_tags`)
---@param ctx FeyVaultCtx
---@param title_node TSNode|nil
---@return string
local function title_text(ctx, title_node)
  if not title_node then return '' end
  return tag_region.title_text(title_node, ctx.src, ctx.meta_set)
end

-- Data values (README VII) --------------------------------------------------

local list_value, tag_value

---@param ctx FeyVaultCtx
---@param block TSNode fenced block
---@return string
local function fenced_string(ctx, block)
  local open = block:field('openfence')[1]
  local close = block:field('closefence')[1]
  local indent = open and select(2, open:start()) or 0
  local first = (open and open:start() or block:start()) + 1 -- 0-indexed row of the line after the fence
  local last = close and (close:start() - 1) or (last_line(block) - 1)
  local out = {}
  for row = first, last do
    local line = ctx.lines[row + 1] or ''
    local lead = #line:match('^[ \t]*')
    out[#out + 1] = line:sub(math.min(lead, indent) + 1)
  end
  return table.concat(out, '\n')
end

---Inline text of a paragraph: wrapped lines are joined by a single space
---@param ctx FeyVaultCtx
---@param paragraphs TSNode[]
local function paragraphs_text(ctx, paragraphs)
  local parts = {}
  for _, p in ipairs(paragraphs) do
    table.insert(parts, trim((text(ctx, p):gsub('%s*\n%s*', ' '))))
  end
  return table.concat(parts, '\n\n')
end

---@param ctx FeyVaultCtx
---@param node TSNode
---@return FeyVaultParsedTag|nil
local function data_tag(ctx, node)
  if not KIND[node:type()] then return nil end
  local tag = parse_tag(ctx, node)
  if tag and DATA_TAGS[tag.name] then return tag end
end

---Merge `src` into `dst`. Both are tables (maps) or both lists.
---@return boolean ok
local function merge(ctx, node, dst, src, is_array)
  if is_array then
    vim.list_extend(dst, src)
    return true
  end
  for k, v in pairs(src) do
    if dst[k] ~= nil then err(ctx, node, ('key defined twice: %s'):format(k)) else dst[k] = v end
  end
  return true
end

---Key of a bullet (README VII.B): the anonymous text without its trailing `_`
---@param ctx FeyVaultCtx
---@param bullet TSNode
---@return string|nil
local function bullet_key(ctx, bullet)
  local segment = bullet:named_child(0)
  if not segment then return nil end
  local index = text(ctx, segment):match('^([%w_]*).$') or ''
  local anon = index:match(constants.segment_enumeration)
  if not anon then return nil end
  local key = anon:sub(1, -2)
  return key ~= '' and key or nil
end

---@param ctx FeyVaultCtx
---@param item TSNode listitem
---@return any value
local function item_value(ctx, item)
  local value, found = nil, false
  local paragraphs = {}
  local function take(v, node)
    if found then err(ctx, node, 'list item holds more than one value') return end
    value, found = v, true
  end

  for _, node in ipairs(item:field('contents')) do
    local t = node:type()
    if t == 'list' then
      take(list_value(ctx, node), node)
    elseif t == 'block' then
      take(fenced_string(ctx, node), node)
    elseif t == 'paragraph' then
      table.insert(paragraphs, node)
    elseif KIND[t] then
      local tag = data_tag(ctx, node)
      if tag then take(tag_value(ctx, tag), node) end
    end
  end

  if #paragraphs > 0 then
    -- an inline data scope tag is the value on its own (`key_:  {# array, a, b #}`)
    local only_tag
    if #paragraphs == 1 then
      local children = {}
      for child in paragraphs[1]:iter_children() do
        if child:named() then table.insert(children, child) end
      end
      if #children == 1 and children[1]:type() == 'scope_tag' then only_tag = data_tag(ctx, children[1]) end
    end
    if only_tag then
      take(tag_value(ctx, only_tag), paragraphs[1])
    else
      take(scalar(paragraphs_text(ctx, paragraphs)), paragraphs[1])
    end
  end
  return value
end

---A sublist is a table when all bullets have keys and an array when none do
---@param ctx FeyVaultCtx
---@param list TSNode
---@return table
function list_value(ctx, list)
  local entries, keyed, unkeyed = {}, 0, 0
  for _, item in ipairs(list:named_children()) do
    if item:type() == 'listitem' then
      local bullet = item:field('bullet')[1]
      local key = bullet and bullet_key(ctx, bullet)
      if key then keyed = keyed + 1 else unkeyed = unkeyed + 1 end
      table.insert(entries, { key = key, value = item_value(ctx, item), node = item })
    end
  end

  if keyed > 0 and unkeyed > 0 then err(ctx, list, 'list mixes keyed and unkeyed bullets') end
  if keyed == 0 then
    local arr = {}
    for i, e in ipairs(entries) do
      arr[i] = e.value == nil and vim.NIL or e.value
    end
    return arr
  end
  local map = vim.empty_dict()
  for _, e in ipairs(entries) do
    if e.key then
      if map[e.key] ~= nil then err(ctx, e.node, ('key defined twice: %s'):format(e.key)) end
      map[e.key] = e.value == nil and vim.NIL or e.value
    end
  end
  return map
end

---Lists in the body of a data tag, merged
---@param ctx FeyVaultCtx
---@param tag FeyVaultParsedTag
---@param is_array boolean
---@param into table
local function merge_body_lists(ctx, tag, is_array, into)
  if not tag.body then return end
  for _, child in ipairs(tag.body:named_children()) do
    if child:type() == 'list' then
      local v = list_value(ctx, child)
      local v_is_array = vim.islist(v) and not vim.tbl_isempty(v) or (vim.tbl_isempty(v) and is_array)
      if v_is_array ~= is_array then
        err(ctx, child, ('%s tag holds a %s'):format(tag.name, is_array and 'table' or 'list'))
      else
        merge(ctx, child, into, v, is_array)
      end
    end
  end
end

---@param ctx FeyVaultCtx
---@param tag FeyVaultParsedTag
---@return any
function tag_value(ctx, tag)
  if tag.name == 'table' then
    local t = vim.empty_dict()
    if #tag.values > 0 then err(ctx, tag.node, 'table tag takes only key: value pairs') end
    for _, k in ipairs(tag.order) do
      t[k] = scalar(tag.attrs[k])
    end
    merge_body_lists(ctx, tag, false, t)
    return t
  elseif tag.name == 'array' then
    local arr = {}
    if #tag.order > 0 then err(ctx, tag.node, 'array tag takes only plain values') end
    for _, v in ipairs(tag.values) do
      table.insert(arr, scalar(v))
    end
    merge_body_lists(ctx, tag, true, arr)
    return arr
  end

  -- value
  if tag.values[1] ~= nil then return scalar(tag.values[1]) end
  if tag.body then
    for _, child in ipairs(tag.body:named_children()) do
      if child:type() == 'block' then return fenced_string(ctx, child) end
    end
  end
  return nil
end

---Data tags at the top level of a section body
---@param ctx FeyVaultCtx
---@param body TSNode|nil
---@return FeyVaultParsedTag[]
local function body_data_tags(ctx, body)
  local tags = {}
  if not body then return tags end
  for _, child in ipairs(body:named_children()) do
    local tag = data_tag(ctx, child)
    if tag then table.insert(tags, tag) end
  end
  return tags
end

---README VII.C. `owner` is the document or a section.
---@param ctx FeyVaultCtx
---@param owner TSNode
---@return any
local function section_value(ctx, owner)
  local tags = body_data_tags(ctx, owner:field('body')[1])
  local subs = owner:field('subsection')

  if #subs == 0 then
    if #tags == 0 then return nil end
    local all_tables = true
    for _, t in ipairs(tags) do
      all_tables = all_tables and t.name == 'table'
    end
    if all_tables then
      local merged = vim.empty_dict()
      for _, t in ipairs(tags) do
        merge(ctx, t.node, merged, tag_value(ctx, t), false)
      end
      return merged
    end
    if #tags > 1 then err(ctx, tags[2].node, 'section holds more than one data value') end
    return tag_value(ctx, tags[1])
  end

  local function title_of(section)
    local heading = section:field('heading')[1]
    local title = heading and heading:field('title')[1]
    return title and title_text(ctx, title) or nil
  end

  local array_n, key_n = 0, 0
  for _, s in ipairs(subs) do
    local title = title_of(s)
    if title == nil or title == '' then err(ctx, s, 'heading without a title in a data section')
    elseif title == '_' then array_n = array_n + 1 else key_n = key_n + 1 end
  end
  if array_n > 0 and key_n > 0 then err(ctx, owner, 'headings mix keys and `_`') end

  if array_n > 0 and key_n == 0 then
    if #tags > 0 then err(ctx, tags[1].node, 'a section with `_` headings may not hold data in its body') end
    local arr = {}
    for _, s in ipairs(subs) do
      local v = section_value(ctx, s)
      table.insert(arr, v == nil and vim.NIL or v)
    end
    return arr
  end

  local map = vim.empty_dict()
  for _, t in ipairs(tags) do
    if t.name == 'table' then
      merge(ctx, t.node, map, tag_value(ctx, t), false)
    else
      err(ctx, t.node, 'only table tags may sit beside key headings')
    end
  end
  for _, s in ipairs(subs) do
    local title = title_of(s)
    if title and title ~= '' and title ~= '_' then
      if map[title] ~= nil then err(ctx, s, ('key defined twice: %s'):format(title)) end
      local v = section_value(ctx, s)
      map[title] = v == nil and vim.NIL or v
    end
  end
  return map
end

-- Outline -------------------------------------------------------------------

---@param ctx FeyVaultCtx
---@param root TSNode
---@return FeyVaultHeading[] headings
---@return table<integer, integer> ord_by_node
local function collect_headings(ctx, root)
  local headings, ord_by_node = {}, {}

  local function walk(owner, parent)
    for _, section in ipairs(owner:field('subsection')) do
      local heading = section:field('heading')[1]
      local sig = heading and heading:field('signature')[1]
      local title_node = heading and heading:field('title')[1]
      local level = 0
      if sig then
        for _, c in ipairs(sig:named_children()) do
          if c:type() == 'segment' then level = level + 1 end
        end
      end
      local title = title_text(ctx, title_node)

      local h = {
        ord = #headings + 1,
        parent_ord = parent and parent.ord or nil,
        level = level,
        signature = sig and trim(text(ctx, sig)) or '',
        title = title,
        path = parent and (parent.path .. '/' .. title) or title,
        line = section:start() + 1,
        end_line = last_line(section),
        props = {},
      }
      if #section:field('subsection') == 0 then h.data = section_value(ctx, section) end
      table.insert(headings, h)
      ord_by_node[section:id()] = h.ord
      walk(section, h)
    end
  end
  walk(root, nil)
  return headings, ord_by_node
end

-- Labels --------------------------------------------------------------------

---@param v any
---@return string[]
local function label_strings(v)
  local out = {}
  if type(v) == 'string' then
    for piece in v:gmatch('[^,;]+') do
      local part = trim(piece)
      if part ~= '' then table.insert(out, part) end
    end
  elseif type(v) == 'table' then
    for _, item in ipairs(v) do
      vim.list_extend(out, label_strings(item))
    end
  elseif type(v) == 'number' or type(v) == 'boolean' then
    table.insert(out, tostring(v))
  end
  return out
end

M.scalar = scalar

-- Entry point ---------------------------------------------------------------

---@param src string Fey source
---@param opts? FeyVaultExtractOpts
---@return FeyVaultFileMeta
function M.extract(src, opts)
  opts = opts or {}
  local label_tags = vim.list_extend({}, opts.label_tags or { 'label', 'labels' })
  local link_tags = vim.list_extend({}, opts.link_tags or { 'link', 'section' })
  local label_set, link_set = {}, {}
  for _, n in ipairs(label_tags) do label_set[n] = true end
  for _, n in ipairs(link_tags) do link_set[n] = true end

  local meta_set = {}
  for _, n in ipairs(opts.meta_tags or DEFAULT_META_TAGS) do meta_set[n] = true end
  local date_kinds = opts.date_tags or { date = 'date', scheduled = 'scheduled', deadline = 'deadline', closed = 'closed' }
  local status_name = opts.status_tag or 'status'
  local prop_name = opts.prop_tag or 'prop'
  local ctx = { src = src, lines = vim.split(src, '\n', { plain = true }), errors = {}, opts = opts, meta_set = meta_set }
  local root = vim.treesitter.get_string_parser(src, 'fey'):parse()[1]:root()
  if root:has_error() then table.insert(ctx.errors, 'syntax errors in file') end

  local headings, ord_by_node = collect_headings(ctx, root)
  local data = section_value(ctx, root)

  ---@type FeyVaultFileMeta
  local meta = {
    title = '',
    data = data,
    headings = headings,
    tags = {},
    links = {},
    labels = {},
    dates = {},
    tasks = {},
    properties = {},
    errors = ctx.errors,
  }

  -- tags, links and labels
  local seen_label = {}
  local function add_label(label, heading_ord, container, line)
    local key = (heading_ord or 0) .. '\0' .. label:lower()
    if seen_label[key] then return end
    seen_label[key] = true
    table.insert(meta.labels, { label = label, heading_ord = heading_ord, container = container, line = line })
  end

  -- where tags sit: the metadata region of every section, found once
  local region_cache = {}
  local function region_of(node, section)
    if not section then return 'document' end
    local set = region_cache[section:id()]
    if not set then
      set = {}
      for _, e in ipairs((tag_region.entries(section))) do
        set[e.node:id()] = e.region
      end
      region_cache[section:id()] = set
    end
    return set[node:id()] or 'text'
  end

  for _, node in get_tag_query():iter_captures(root, src) do
    local tag = parse_tag(ctx, node)
    if tag then
      local heading_ord, section
      local p = node:parent()
      while p do
        if p:type() == 'section' then
          section = p
          heading_ord = ord_by_node[p:id()]
          break
        end
        p = p:parent()
      end
      local line = node:start() + 1
      local region = region_of(node, section)

      table.insert(meta.tags, {
        kind = tag.kind,
        name = tag.name,
        line = line,
        heading_ord = heading_ord,
        region = region,
        values = tag.values,
        attrs = tag.attrs,
        order = tag.order,
      })

      if link_set[tag.name] and tag.values[1] then
        table.insert(meta.links, {
          kind = tag.name,
          target = tag.values[1],
          description = tag.attrs.desc or tag.values[2],
          values = tag.values,
          attrs = tag.attrs,
          line = line,
          heading_ord = heading_ord,
        })
      end

      if label_set[tag.name] then
        for _, v in ipairs(tag.values) do
          for _, l in ipairs(label_strings(v)) do add_label(l, heading_ord, region, line) end
        end
      end
      for k, v in pairs(tag.attrs) do
        if label_set[k] then
          for _, l in ipairs(label_strings(v)) do add_label(l, heading_ord, 'data', line) end
          -- `{# array; labels: a, b #}` parses as the pair `labels: a` plus the plain value `b`
          if tag.name == 'array' then
            for _, pv in ipairs(tag.values) do
              for _, l in ipairs(label_strings(pv)) do add_label(l, heading_ord, 'data', line) end
            end
          end
        end
      end
    end
  end

  -- dates, tasks and the properties of headings, from the same tags
  local todo_lookup = opts.todo_lookup and opts.todo_lookup(type(data) == 'table' and data.todo or nil)
    or { TODO = { type = 'TODO' }, DONE = { type = 'DONE' } }
  for _, node in get_tag_query():iter_captures(root, src) do
    local tag = parse_tag(ctx, node)
    if tag and not node:has_error() then
      local kind = date_kinds[tag.name]
      local heading_ord
      local section
      local p = node:parent()
      while p do
        if p:type() == 'section' then
          section = p
          heading_ord = ord_by_node[p:id()]
          break
        end
        p = p:parent()
      end
      local row, col = node:start()

      if kind then
        local found = Date.from_parts(tag.name, tag.values, tag.attrs)
        local first, second = found[1], found[2]
        if first then
          local repeater, warn
          for _, adj in ipairs(first.adjustments) do
            if not repeater and adj:match('^[%+%.]?%+%d+') then repeater = adj end
            if not warn and adj:match('^%-%d+') then warn = adj end
          end
          local end_ts = second and second.timestamp or first.timestamp_end
          table.insert(meta.dates, {
            heading_ord = heading_ord,
            line = row + 1,
            col = col + 1,
            kind = kind,
            active = first.active,
            start_ts = first.timestamp,
            start_time = first:has_time(),
            end_ts = end_ts,
            end_time = (second and second:has_time()) or first.timestamp_end ~= nil,
            repeater = repeater,
            warn = warn,
          })
        else
          err(ctx, node, ('not a date: %s'):format(tag.values[1] or ''))
        end
      end

      local region = region_of(node, section)

      -- the status tag has to be the first thing of a title: `{# status, TODO, A #}`
      if tag.name == status_name and region == 'title' and heading_ord then
        local title = node:parent()
        local first_child = title and title:child(0)
        if first_child and first_child:id() == node:id() then
          local keyword = tag.values[1]
          local priority = tag.values[2] or tag.attrs.priority
          table.insert(meta.tasks, {
            heading_ord = heading_ord,
            line = row + 1,
            kind = 'heading',
            state = keyword,
            done = keyword ~= nil and todo_lookup[keyword] ~= nil and todo_lookup[keyword].type == 'DONE',
            priority = priority,
            title = headings[heading_ord].title,
          })
        end
      end

      if tag.name == prop_name and heading_ord and (region == 'title' or region == 'body') then
        local props = headings[heading_ord].props
        for k, v in pairs(tag.attrs) do
          props[k:lower()] = v
        end
      end
    end
  end

  -- document level data: properties, labels, title
  if type(data) == 'table' and not vim.islist(data) then
    for k, v in pairs(data) do
      meta.properties[k] = v
      if label_set[k] then
        for _, l in ipairs(label_strings(v)) do add_label(l, nil, 'data') end
      end
    end
  end

  local title = type(data) == 'table' and data.title
  if type(title) ~= 'string' or title == '' then
    title = nil
    for _, h in ipairs(headings) do
      if h.level == 1 and h.title ~= '' and h.title ~= '_' then
        title = h.title
        break
      end
    end
  end
  meta.title = title or ''
  return meta
end

return M
