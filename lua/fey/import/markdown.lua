-- Markdown into the document of `fey.import.writer`, by walking the tree of the `markdown` and `markdown_inline` tree-sitter parsers (the ones
-- Neovim ships and nvim-treesitter installs). The tree gives the structure. What the grammar does not know is Obsidian's own syntax, and that
-- is matched on the plain text between the nodes of the tree, not tokenized: `[[wikilinks]]` and `![[embeds]]` (they come out of the tree as
-- shortcut links, recognised by their text), `#tags`, `$math$`, `==highlights==`, `%%comments%%`, `[!callouts]`, `[^footnotes]:` definitions, task
-- marks other than a space and an `x`, and the dates of the Tasks plugin.
local M = {}

local function node_text(ctx, node) return vim.treesitter.get_node_text(node, ctx.src) end

---The first child of a type (the inline grammar names its parts but gives them no fields)
---@param node TSNode
---@param kind string
---@return TSNode|nil
local function child_of(node, kind)
  for c in node:iter_children() do
    if c:type() == kind then return c end
  end
end

---@param node TSNode
---@return integer from, integer to byte range, `to` exclusive
local function span(node)
  local _, _, from = node:start()
  local _, _, to = node:end_()
  return from, to
end

-- the text of a byte range without the prefixes the block structure puts in front of the lines (`> `, the indent of a list item)
local function slice(ctx, from, to)
  local cont = ctx.cont
  -- the first prefix that ends after `from`
  local lo, hi = 1, #cont + 1
  while lo < hi do
    local mid = math.floor((lo + hi) / 2)
    if cont[mid][2] <= from then
      lo = mid + 1
    else
      hi = mid
    end
  end
  local out, pos = {}, from
  for i = lo, #cont do
    local c = cont[i]
    if c[1] >= to then break end
    if c[1] >= pos and c[2] <= to then
      out[#out + 1] = ctx.src:sub(pos + 1, c[1])
      pos = c[2]
    end
  end
  out[#out + 1] = ctx.src:sub(pos + 1, to)
  return table.concat(out)
end

-- inline ----------------------------------------------------------------------------------------------------------------------

---Where a link leads: a note of the vault becomes a `.fey` file
---@param ctx table
---@param target string
local function target_of(ctx, target)
  target = vim.trim(target)
  if target == '' or target:match('^%a[%w+.-]*:') or target:match('^#') then return target end
  if ctx.opts.link_extension == false then return target end
  local path, anchor = target:match('^([^#]*)(#?.*)$')
  path = path:gsub('%%20', ' ')
  if path:match('%.md$') or path:match('%.markdown$') then
    path = path:gsub('%.[^./]+$', '.fey')
  elseif not path:match('%.[%w]+$') then
    path = path .. '.fey'
  else
    return target
  end
  return path .. anchor
end

local function wikilink(ctx, inner, embed)
  local target, alias = inner:match('^(.-)|(.*)$')
  target = target or inner
  local file, heading = target:match('^([^#]*)#(.*)$')
  file = file or target
  heading = heading and heading:gsub('^%^.*$', '') or nil
  local href = file ~= '' and target_of(ctx, file) or ''
  local desc = alias or (heading and heading ~= '' and (file ~= '' and (file .. ' > ' .. heading) or heading)) or file
  if embed then return { t = 'link', href = href, embed = true, children = { { t = 'text', s = alias or file } } } end
  if href == '' then return { t = 'text', s = desc } end
  return { t = 'link', href = href, children = { { t = 'text', s = desc } } }
end

local DATES = {
  ['📅'] = true,
  ['⏳'] = true,
  ['🛫'] = true,
  ['✅'] = true,
  ['➕'] = true,
  ['❌'] = true,
}

-- Obsidian syntax in the text between the nodes of the tree
local function rich(ctx, text)
  local items = {}
  local function add_text(s)
    if s ~= '' then
      local last = items[#items]
      if last and last.t == 'text' then
        last.s = last.s .. s
      else
        items[#items + 1] = { t = 'text', s = s }
      end
    end
  end
  local pos = 1
  while pos <= #text do
    -- the nearest of the constructs, searched from `pos`
    local best
    local function try(start, stop, make)
      if start and (not best or start < best.start) then best = { start = start, stop = stop, make = make } end
    end
    do
      local s, e, a = text:find('%%%%(.-)%%%%', pos)
      try(s, e, function()
        ctx.dropped.comments = true
        return nil
      end)
    end
    do
      local s, e, a = text:find('~~([^~\n]+)~~', pos)
      try(s, e, function() return { t = 'em', kind = 'strike', children = { { t = 'text', s = a } } } end)
    end
    do
      local s, e, a = text:find('==([^=\n]+)==', pos)
      try(s, e, function()
        ctx.dropped.highlight = true
        return { t = 'text', s = a }
      end)
    end
    do
      local s, e, a = text:find('%$%$(.-)%$%$', pos)
      try(s, e, function() return { t = 'math', s = a } end)
    end
    do
      -- inline math: no blank inside the dollars, not money (a digit after the closing one), not a word that has a dollar in it
      local from = pos
      local s, e, a
      while true do
        s, e, a = text:find('%$([^%s$][^$\n]-[^%s$\\])%$', from)
        if not s then
          s, e, a = text:find('%$([^%s$\\])%$', from)
        end
        if not s then break end
        local before, after = text:sub(s - 1, s - 1), text:sub(e + 1, e + 1)
        if not (before:match('[%w$]') and s > 1) and not after:match('[%w$]') then break end
        from = s + 1
      end
      try(s, e, function() return { t = 'math', s = a } end)
    end
    do
      -- a tag starts the text or follows a blank, and has a letter in it
      local from = pos
      local s, e, name
      while true do
        s, e, name = text:find('#([%a_][%w_/-]*)', from)
        if not s or s == 1 or text:sub(s - 1, s - 1):match('%s') then break end
        from = s + 1
      end
      try(s, e, function() return { t = 'label', name = name } end)
    end
    do
      local s, e, emoji, date = text:find('([📅⏳🛫✅➕❌])%s*(%d%d%d%d%-%d%d%-%d%d)', pos)
      try(s, e, function() return { t = 'date', value = date, emoji = emoji } end)
    end
    do
      local s, e = text:find('%s%^[%w-]+$', pos)
      try(s, e, function() return nil end)
    end
    if not best then
      add_text(text:sub(pos))
      break
    end
    add_text(text:sub(pos, best.start - 1))
    local item = best.make()
    if item and item.t == 'date' then
      add_text(item.emoji .. ' ')
      item.emoji = nil
    end
    if item then
      if item.t == 'text' then
        add_text(item.s)
      else
        items[#items + 1] = item
      end
    end
    pos = best.stop + 1
  end
  return items
end

local HTML_ENTITIES = { ['&amp;'] = '&', ['&lt;'] = '<', ['&gt;'] = '>', ['&quot;'] = '"', ['&nbsp;'] = ' ', ['&#39;'] = "'" }

local convert

---@param ctx table
---@param node TSNode a node of the inline tree
---@param from integer
---@param to integer
---@return table[]
convert = function(ctx, node, from, to)
  local items = {}
  local pos = from
  local function gap(upto)
    if upto > pos then vim.list_extend(items, rich(ctx, slice(ctx, pos, upto))) end
  end
  local function push(item)
    if item then items[#items + 1] = item end
  end
  for child in node:iter_children() do
    if child:named() then
      local t = child:type()
      local cf, ct = span(child)
      if cf >= pos and cf < to then
        -- `[[note]]` comes out of the tree as a shortcut link in a pair of brackets
        local wrapped = t == 'shortcut_link'
          and ctx.src:sub(cf, cf) == '['
          and ctx.src:sub(ct + 1, ct + 1) == ']'
          and cf - 1 >= pos
        gap(wrapped and cf - 1 or cf)
        pos = wrapped and ct + 1 or ct
        if t == 'emphasis' or t == 'strong_emphasis' or t == 'strikethrough' then
          local delims = {}
          for d in child:iter_children() do
            if d:type() == 'emphasis_delimiter' or d:type() == 'strikethrough_delimiter' then delims[#delims + 1] = d end
          end
          local n = math.floor(#delims / 2)
          local _, inner_from = span(delims[n])
          local inner_to = span(delims[n + 1])
          local kind = t == 'emphasis' and 'italic' or t == 'strong_emphasis' and 'bold' or 'strike'
          local children = convert(ctx, child, inner_from, inner_to)
          -- `~~x~~` is a strikethrough in a strikethrough in this grammar
          if kind == 'strike' and #children == 1 and children[1].t == 'em' and children[1].kind == 'strike' then
            children = children[1].children
          end
          push({ t = 'em', kind = kind, children = children })
        elseif t == 'code_span' then
          local delims = {}
          for d in child:iter_children() do
            if d:type() == 'code_span_delimiter' then delims[#delims + 1] = d end
          end
          local _, a = span(delims[1])
          local b = span(delims[#delims])
          local s = ctx.src:sub(a + 1, b)
          if s:match('^ .* $') and s:match('%S') then s = s:sub(2, -2) end
          push({ t = 'code', s = s })
        elseif t == 'inline_link' then
          local text_node = child_of(child, 'link_text')
          local dest = child_of(child, 'link_destination')
          local children = {}
          if text_node then
            local tf, tt = span(text_node)
            children = convert(ctx, text_node, tf, tt)
          end
          local url = dest and node_text(ctx, dest):gsub('^<(.*)>$', '%1') or ''
          push({ t = 'link', href = target_of(ctx, url), children = children })
        elseif t == 'image' then
          local raw = ctx.src:sub(cf + 1, ct)
          local inner = raw:match('^!%[%[(.-)%]%]$')
          if inner then
            push(wikilink(ctx, inner, true))
          else
            local desc = child_of(child, 'image_description')
            local dest = child_of(child, 'link_destination')
            local alt = desc and node_text(ctx, desc):gsub('^%[', ''):gsub('%]$', '') or ''
            push({
              t = 'link',
              embed = true,
              href = target_of(ctx, dest and node_text(ctx, dest) or ''),
              children = { { t = 'text', s = alt } },
            })
          end
        elseif t == 'shortcut_link' or t == 'collapsed_reference_link' or t == 'full_reference_link' then
          local raw = ctx.src:sub(wrapped and cf or cf + 1, wrapped and ct + 1 or ct)
          local wiki = raw:match('^%[%[(.-)%]%]$')
          local fn = raw:match('^%[%^([^%]]+)%]$')
          if wiki then
            push(wikilink(ctx, wiki, false))
          elseif fn then
            push({ t = 'fnref', label = fn })
          else
            local label = child_of(child, 'link_label')
            local text_node = child_of(child, 'link_text')
            local key = (label and node_text(ctx, label) or text_node and node_text(ctx, text_node) or ''):lower()
            local ref = ctx.refs[key]
            if ref and text_node then
              local tf, tt = span(text_node)
              push({ t = 'link', href = target_of(ctx, ref), children = convert(ctx, text_node, tf, tt) })
            else
              vim.list_extend(items, rich(ctx, raw))
            end
          end
        elseif t == 'uri_autolink' or t == 'email_autolink' then
          local url = node_text(ctx, child):gsub('^<', ''):gsub('>$', '')
          push({
            t = 'link',
            href = t == 'email_autolink' and ('mailto:' .. url) or url,
            children = { { t = 'text', s = url } },
          })
        elseif t == 'hard_line_break' then
          push({ t = 'br' })
        elseif t == 'backslash_escape' then
          push({ t = 'text', s = node_text(ctx, child):sub(2) })
        elseif t == 'entity_reference' or t == 'numeric_character_reference' then
          local raw = node_text(ctx, child)
          local code = raw:match('^&#(%d+);$')
          local hex = raw:match('^&#[xX](%x+);$')
          local s = HTML_ENTITIES[raw]
            or (code and vim.fn.nr2char(tonumber(code)))
            or (hex and vim.fn.nr2char(tonumber(hex, 16)))
            or raw
          push({ t = 'text', s = s })
        elseif t == 'html_tag' then
          local raw = node_text(ctx, child)
          if raw:match('^<br%s*/?>$') then
            push({ t = 'br' })
          else
            ctx.dropped.html = true
          end
        elseif t == 'latex_block' then
          local tex = node_text(ctx, child):gsub('^%$+', ''):gsub('%$+$', '')
          -- money and shell variables have dollars too
          local before, after = ctx.src:sub(cf, cf), ctx.src:sub(ct + 1, ct + 1)
          if tex:match('^%s') or tex:match('%s$') or (cf > 0 and before:match('[%w$]')) or after:match('[%w$]') then
            push({ t = 'text', s = node_text(ctx, child) })
          else
            push({ t = 'math', s = tex })
          end
        else
          vim.list_extend(items, rich(ctx, slice(ctx, cf, ct)))
        end
      end
    end
  end
  gap(to)
  -- text next to text is one text (a bracket that was no link, the words around it)
  local merged = {}
  for _, item in ipairs(items) do
    local last = merged[#merged]
    if item.t == 'text' and last and last.t == 'text' then
      last.s = last.s .. item.s
    else
      merged[#merged + 1] = item
    end
  end
  return merged
end

---Inline items of a node of the block tree that holds an `inline` (a paragraph, a heading, a cell)
---@param ctx table
---@param inline TSNode the `inline` node of the block tree
---@param from? integer start of the text, when a prefix of it was read already
---@return table[]
local function inlines(ctx, inline, from)
  local sr, sc, er, ec = inline:range()
  local root = ctx.roots[('%d:%d:%d:%d'):format(sr, sc, er, ec)]
  local f, t = span(inline)
  if not root then return rich(ctx, slice(ctx, from or f, t)) end
  local items = convert(ctx, root, from or f, t)
  local first, last = items[1], items[#items]
  if first and first.t == 'text' then first.s = first.s:gsub('^%s+', '') end
  if last and last.t == 'text' then last.s = last.s:gsub('%s+$', '') end
  if last and last.t == 'br' then items[#items] = nil end
  return items
end

-- blocks ------------------------------------------------------------------------------------------------------------------

local blocks_of

local function inline_of(node)
  for c in node:iter_children() do
    if c:type() == 'inline' then return c end
  end
end

local CALLOUTS = {
  note = 'note',
  info = 'info',
  todo = 'todo',
  tip = 'tip',
  hint = 'tip',
  important = 'important',
  success = 'success',
  check = 'success',
  done = 'success',
  question = 'question',
  help = 'question',
  faq = 'question',
  warning = 'warning',
  caution = 'warning',
  attention = 'warning',
  failure = 'failure',
  fail = 'failure',
  missing = 'failure',
  danger = 'danger',
  error = 'danger',
  bug = 'bug',
  example = 'example',
  quote = 'quote',
  cite = 'quote',
  abstract = 'abstract',
  summary = 'abstract',
  tldr = 'abstract',
}

---@param ctx table
---@param para TSNode
local function paragraph(ctx, para)
  local inline = inline_of(para)
  if not inline then return {} end
  local f, t = span(inline)
  local raw = vim.trim(slice(ctx, f, t))
  -- display math and comments, written over several lines
  local math = raw:match('^%$%$(.-)%$%$$')
  if math then return { { t = 'math', s = math } } end
  local comment = raw:match('^%%%%(.-)%%%%$')
  if comment then return { { t = 'comment', s = comment } } end
  -- a footnote definition
  local label, rest = raw:match('^%[%^([^%]]+)%]:%s*(.*)$')
  if label then
    local prefix = raw:find(rest, 1, true) or #raw + 1
    local start = f + (slice(ctx, f, t):find(rest ~= '' and rest:sub(1, 1) or '', 1, true) or 1) - 1
    local items = rest ~= '' and inlines(ctx, inline, start) or {}
    return { { t = 'fndef', label = label, blocks = { { t = 'paragraph', inlines = items } } } }
  end
  local items = inlines(ctx, inline)
  if #items == 0 then return {} end
  return { { t = 'paragraph', inlines = items } }
end

local function list(ctx, node)
  local items, ordered = {}, false
  for _, item in ipairs(node:named_children()) do
    if item:type() == 'list_item' then
      local box
      for c in item:iter_children() do
        local t = c:type()
        if t == 'list_marker_dot' or t == 'list_marker_parenthesis' then ordered = true end
        if t == 'task_list_marker_unchecked' then box = ' ' end
        if t == 'task_list_marker_checked' then box = 'x' end
      end
      local blocks = blocks_of(ctx, item)
      -- Obsidian's other marks come out of the tree as the start of the text: `[/] text`
      if not box and blocks[1] and blocks[1].t == 'paragraph' then
        local first = blocks[1].inlines[1]
        if first and first.t == 'text' then
          local mark, rest = first.s:match('^%[([^%s%[%]])%]%s(.*)$')
          if mark and not mark:match('%d') then
            box = mark
            first.s = rest
          end
        end
      end
      items[#items + 1] = { box = box, blocks = blocks }
    end
  end
  return { { t = 'list', ordered = ordered, items = items } }
end

local function fenced(ctx, node)
  local lang
  for c in node:iter_children() do
    if c:type() == 'info_string' then
      local l = child_of(c, 'language')
      lang = l and vim.trim(node_text(ctx, l)) or vim.trim(node_text(ctx, c))
      lang = lang ~= '' and lang:match('^%S+') or nil
    end
  end
  local content
  for c in node:iter_children() do
    if c:type() == 'code_fence_content' then content = c end
  end
  local text = ''
  if content then
    local f, t = span(content)
    text = slice(ctx, f, t):gsub('\n$', '')
  end
  if lang == 'math' or lang == 'latex' and false then return { { t = 'math', s = text } } end
  return { { t = 'code', lang = lang ~= '' and lang or nil, text = text } }
end

local function quote(ctx, node)
  local blocks = blocks_of(ctx, node)
  local callout, title
  local first = blocks[1]
  if first and first.t == 'paragraph' and first.inlines[1] and first.inlines[1].t == 'text' then
    local kind, fold, rest = first.inlines[1].s:match('^%[!([%w_-]+)%]([+-]?)[ \t]*(.*)$')
    if kind then
      callout = CALLOUTS[kind:lower()] or kind:lower()
      -- the first line is the title, the rest of the paragraph goes on
      local line, more = rest:match('^(.-)\n(.*)$')
      title = line or rest
      first.inlines[1].s = more or ''
      if more == nil or (first.inlines[1].s == '' and #first.inlines == 1) then table.remove(blocks, 1) end
      if title == '' then title = callout:sub(1, 1):upper() .. callout:sub(2) end
    end
  end
  return { { t = 'quote', blocks = blocks, callout = callout, title = title } }
end

local function table_of(ctx, node)
  local header, rows = nil, {}
  local function cells(row)
    local out = {}
    for c in row:iter_children() do
      if c:type() == 'pipe_table_cell' then
        local sr, sc, er, ec = c:range()
        local root = ctx.roots[('%d:%d:%d:%d'):format(sr, sc, er, ec)]
        if root then
          local f, t = span(c)
          local items = convert(ctx, root, f, t)
          local first, last = items[1], items[#items]
          if first and first.t == 'text' then first.s = first.s:gsub('^%s+', '') end
          if last and last.t == 'text' then last.s = last.s:gsub('%s+$', '') end
          out[#out + 1] = items
        else
          out[#out + 1] = rich(ctx, vim.trim(node_text(ctx, c)))
        end
      end
    end
    return out
  end
  for c in node:iter_children() do
    if c:type() == 'pipe_table_header' then
      header = cells(c)
    elseif c:type() == 'pipe_table_row' then
      rows[#rows + 1] = cells(c)
    end
  end
  return { { t = 'table', header = header, rows = rows } }
end

---@param ctx table
---@param node TSNode
---@return table[]
blocks_of = function(ctx, node)
  local out = {}
  for _, c in ipairs(node:named_children()) do
    local t = c:type()
    local made
    if t == 'paragraph' then
      made = paragraph(ctx, c)
    elseif t == 'list' then
      made = list(ctx, c)
    elseif t == 'fenced_code_block' then
      made = fenced(ctx, c)
    elseif t == 'indented_code_block' then
      local f, e = span(c)
      made = { { t = 'code', text = vim.trim(slice(ctx, f, e)):gsub('\n    ', '\n') } }
    elseif t == 'block_quote' then
      made = quote(ctx, c)
    elseif t == 'pipe_table' then
      made = table_of(ctx, c)
    elseif t == 'html_block' then
      local raw = vim.trim(node_text(ctx, c))
      local comment = raw:match('^<!%-%-(.-)%-%->$')
      if comment then
        made = { { t = 'comment', s = comment } }
      else
        ctx.dropped.html_block = true
        made = { { t = 'code', lang = 'html', text = raw } }
      end
    elseif
      t == 'thematic_break'
      or t == 'link_reference_definition'
      or t == 'minus_metadata'
      or t == 'plus_metadata'
      or t == 'block_continuation'
    then
      made = nil
    elseif t == 'section' or t == 'atx_heading' or t == 'setext_heading' then
      made = nil
    end
    if made then vim.list_extend(out, made) end
  end
  return out
end

-- sections and the front matter --------------------------------------------------------------------------------------------

local function key_of(k) return (k:lower():gsub('[^%w_]', '_'):gsub('^(%d)', '_%1')) end

---The front matter of a note: `key: value`, `key: [a, b]`, and `key:` followed by a list. Nested maps are left out.
---@param ctx table
---@param text string
---@param doc table
local function front_matter(ctx, text, doc)
  local current
  local function put(key, value)
    if key == 'tags' or key == 'tag' then
      local list = type(value) == 'table' and value or vim.split(value, '[,%s]+', { trimempty = true })
      for _, l in ipairs(list) do
        l = l:gsub('^#', ''):gsub('%s+', '-')
        if l ~= '' then doc.labels[#doc.labels + 1] = l end
      end
      return
    end
    if type(value) == 'table' then value = table.concat(value, ', ') end
    if value ~= '' then doc.data[#doc.data + 1] = { key_of(key), value } end
  end
  local lines = vim.split(text, '\n', { plain = true })
  local i = 1
  while i <= #lines do
    local line = lines[i]
    local key, value = line:match('^([%w_%- ]+):%s*(.-)%s*$')
    if key then
      key = vim.trim(key)
      if value == '' then
        local list = {}
        local j = i + 1
        while lines[j] and lines[j]:match('^%s*%-%s+') do
          list[#list + 1] = (lines[j]:gsub('^%s*%-%s+', ''):gsub('^["\'](.*)["\']$', '%1'))
          j = j + 1
        end
        if #list > 0 then
          put(key, list)
          i = j - 1
        elseif lines[i + 1] and lines[i + 1]:match('^%s+%S') then
          ctx.dropped.yaml = true
          while lines[i + 1] and lines[i + 1]:match('^%s+%S') do
            i = i + 1
          end
        end
      elseif value:match('^[|>]') then
        local parts = {}
        while lines[i + 1] and lines[i + 1]:match('^%s+%S') do
          i = i + 1
          parts[#parts + 1] = vim.trim(lines[i])
        end
        put(key, table.concat(parts, ' '))
      elseif value:match('^%[.*%]$') then
        local list = {}
        for item in value:sub(2, -2):gmatch('[^,]+') do
          list[#list + 1] = (vim.trim(item):gsub('^["\'](.*)["\']$', '%1'))
        end
        put(key, list)
      else
        put(key, (value:gsub('^["\'](.*)["\']$', '%1')))
      end
    end
    i = i + 1
  end
end

---The headings and the blocks between them, in the order of the text. The tree has a section node for every ATX heading, nested by level, but none for
---a setext heading (it is a block of the section it follows), so both are laid out in one list and nested again by level.
---@param ctx table
---@param node TSNode a document or a section
---@param events table[]
local function walk(ctx, node, events)
  for c in node:iter_children() do
    local t = c:type()
    if t == 'section' then
      local h = child_of(c, 'atx_heading')
      if h then
        local level = 1
        for m in h:iter_children() do
          local n = m:type():match('^atx_h(%d)_marker$')
          if n then level = tonumber(n) end
        end
        events[#events + 1] = { heading = true, level = level, inline = h:field('heading_content')[1] or inline_of(h) }
      end
      walk(ctx, c, events)
    elseif t == 'setext_heading' then
      local level = 1
      for m in c:iter_children() do
        local n = m:type():match('^setext_h(%d)_underline$')
        if n then level = tonumber(n) end
      end
      local content = c:field('heading_content')[1]
      events[#events + 1] = { heading = true, level = level, inline = content and (inline_of(content) or content) }
    elseif t ~= 'atx_heading' and c:named() then
      events[#events + 1] = { node = c }
    end
  end
end

---@param ctx table
---@param root TSNode
---@param doc table
local function sections(ctx, root, doc)
  local events = {}
  walk(ctx, root, events)
  local top = { level = 0, sections = doc.sections, nodes = {} }
  local stack = { top }
  local all = { top }
  for _, e in ipairs(events) do
    if e.heading then
      while #stack > 1 and stack[#stack].level >= e.level do
        stack[#stack] = nil
      end
      local parent = stack[#stack]
      local sec = {
        level = e.level,
        title = e.inline and inlines(ctx, e.inline) or {},
        labels = {},
        blocks = {},
        sections = {},
        nodes = {},
      }
      table.insert(parent.sections, sec)
      stack[#stack + 1] = sec
      all[#all + 1] = sec
    else
      table.insert(stack[#stack].nodes, e.node)
    end
  end
  for _, sec in ipairs(all) do
    local nodes = sec.nodes
    local target = sec == top and doc or sec
    target.blocks = blocks_of(ctx, { named_children = function() return nodes end })
    sec.nodes, sec.level = nil, nil
  end
end

---The document of a Markdown text
---@param src string
---@param opts? { link_extension?: boolean }
---@return table doc
function M.parse(src, opts)
  if src:sub(-1) ~= '\n' then src = src .. '\n' end
  local parser = vim.treesitter.get_string_parser(src, 'markdown')
  parser:parse(true)
  local root = parser:trees()[1]:root()
  local ctx = { src = src, opts = opts or {}, cont = {}, roots = {}, refs = {}, dropped = {} }

  local inline_parser = parser:children().markdown_inline
  if inline_parser then
    for _, tree in ipairs(inline_parser:trees()) do
      local r = tree:root()
      local sr, sc, er, ec = r:range()
      ctx.roots[('%d:%d:%d:%d'):format(sr, sc, er, ec)] = r
    end
  end
  -- the prefixes of the lines and the definitions of references, in one pass over the tree
  local function collect(node)
    for c in node:iter_children() do
      local t = c:type()
      if t == 'block_continuation' then
        local f, to = span(c)
        if to > f then ctx.cont[#ctx.cont + 1] = { f, to } end
      elseif t == 'link_reference_definition' then
        local label, dest = child_of(c, 'link_label'), child_of(c, 'link_destination')
        if label and dest then
          ctx.refs[node_text(ctx, label):lower():gsub('^%[', ''):gsub('%]$', '')] = node_text(ctx, dest)
        end
      end
      if c:named() and c:child_count() > 0 then collect(c) end
    end
  end
  collect(root)
  table.sort(ctx.cont, function(a, b) return a[1] < b[1] end)

  local doc = { data = {}, labels = {}, blocks = {}, sections = {}, warnings = {} }
  for c in root:iter_children() do
    if c:type() == 'minus_metadata' then
      local text = node_text(ctx, c):gsub('^%-%-%-\n', ''):gsub('\n%-%-%-%s*$', '')
      front_matter(ctx, text, doc)
    end
  end
  sections(ctx, root, doc)

  local names = {
    highlight = '==highlights== have no Fey form and were kept as plain text',
    comments = 'Obsidian %%comments%% inside a paragraph were dropped',
    html = 'inline HTML tags were dropped',
    html_block = 'HTML blocks were kept as code blocks',
    yaml = 'nested YAML in the front matter was dropped',
  }
  for key, msg in pairs(names) do
    if ctx.dropped[key] then doc.warnings[#doc.warnings + 1] = msg end
  end
  table.sort(doc.warnings)
  return doc
end

return M
