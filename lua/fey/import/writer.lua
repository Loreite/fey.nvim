-- Fey text from the document the importers build (`fey.import.markdown`, `fey.import.org`). The walkers know nothing of Fey syntax and this
-- file knows nothing of Markdown or org: it is the inverse of `fey.export.model` + `fey.export.markdown`.
--
-- The document:
--
--   doc      { data = { {key, value}... }, labels = string[], blocks = Block[], sections = Section[], warnings = string[] }
--   Section  { title = Inline[], status = { keyword, priority }, labels = string[], planning = { {kind, value, active}... },
--              props = { {key, value}... }, logbook = Block[]|nil, clocks = { {start, end, dur}... }, drawers = { {name, blocks}... },
--              blocks = Block[], sections = Section[] }
--   Block    { t = 'paragraph', inlines }  { t = 'list', ordered, items = { { box, blocks }... } }  { t = 'code', lang, name, text }
--            { t = 'quote', blocks, callout, title }  { t = 'table', header, rows }  { t = 'math', s }  { t = 'comment', s }  { t = 'tblfm', s }
--            { t = 'fndef', label, blocks }
--   Inline   { t = 'text', s }  { t = 'em', kind, children }  { t = 'code', s }  { t = 'link', href, children, embed }  { t = 'fnref', label }
--            { t = 'math', s }  { t = 'date', value, active }  { t = 'label', name }  { t = 'br' }
local edit = require('fey.files.elements.tags.edit')
local sequences = require('fey.utils.sequences')

local M = {}

-- the signature of each level: I. I.A. I.A.i. I.A.i.a. and then numbers
local STYLES = { 'roman_upper', 'alpha_upper', 'roman_lower', 'alpha_lower', 'decimal' }

-- a blank line inside a fenced block: it takes the indent of the list item or tag that holds the block, and is a plain blank line otherwise
local BLANK = '\1'

local MARKERS = { bold = '!', italic = '/', underline = '_', strike = '~' }

---@class FeyImportWriter
---@field warnings string[]
local Writer = {}
Writer.__index = Writer

---@param msg string
function Writer:warn(msg)
  if not vim.tbl_contains(self.warnings, msg) then self.warnings[#self.warnings + 1] = msg end
end

-- text ----------------------------------------------------------------------------------------------------------------------

local function opens_marker(s, i)
  local before = i == 1 and ' ' or s:sub(i - 1, i - 1)
  local after = s:sub(i + 1, i + 1)
  return (before:match('[%s%(%[{"\']') ~= nil) and after ~= '' and not after:match('%s')
end

---Plain text as the text of a paragraph: a backslash escapes a character that would open an emphasis span, and the openers of tags cannot be
---escaped (no way to write them in prose), so they are broken with a blank
---@param s string
---@return string
function Writer:text(s)
  if s:find('{#', 1, true) or s:find('{@', 1, true) then
    s = s:gsub('{([#@])', '{ %1')
    self:warn('text with the opener of a tag was changed (a blank was put in it)')
  end
  if s:find('#[', 1, true) or s:find('[#', 1, true) then
    s = s:gsub('#%[', '# ['):gsub('%[#', '[ #')
    self:warn('text with the opener of a tag was changed (a blank was put in it)')
  end
  local out = {}
  for i = 1, #s do
    local c = s:sub(i, i)
    if c == '\\' then
      out[#out + 1] = '\\\\'
    elseif (c == '!' or c == '/' or c == '_' or c == '~' or c == '`') and opens_marker(s, i) then
      out[#out + 1] = '\\' .. c
    else
      out[#out + 1] = c
    end
  end
  return table.concat(out)
end

---Plain text of inline items (the description of a link has no markup)
---@param items table[]
---@return string
local function plain(items)
  local out = {}
  for _, item in ipairs(items or {}) do
    if item.t == 'text' or item.t == 'code' or item.t == 'math' then
      out[#out + 1] = item.s
    elseif item.t == 'br' then
      out[#out + 1] = ' '
    elseif item.t == 'date' then
      out[#out + 1] = item.value
    elseif item.children then
      out[#out + 1] = plain(item.children)
    end
  end
  return (table.concat(out):gsub('%s*\n%s*', ' '))
end
M.plain = plain

---The text of a tag, or nil and why it cannot be written (see `tags.edit.build`)
---@return string|nil text
---@return string|nil err
function Writer:build(name, values, keys, opts)
  local function one(v) return (tostring(v):gsub('%s*\n%s*', ' ')) end
  local clean = {}
  for k, v in pairs(keys or {}) do
    clean[k] = one(v)
  end
  local cv = {}
  for i, v in ipairs(values or {}) do
    cv[i] = one(v)
  end
  return edit.build(name, cv, clean, opts)
end

---A tag, or an empty text (and a note) when it cannot be written
---@return string
function Writer:tag(name, values, keys, opts)
  local text, err = self:build(name, values, keys, opts)
  if not text then
    self:warn('a tag could not be written: ' .. tostring(err))
    return ''
  end
  return text
end

---A link: a tag, or its text when it points nowhere or cannot be written
---@param item table
---@return string
function Writer:link(item)
  local desc = plain(item.children)
  -- a link to nowhere (`[text]()`) is its text
  if (item.href or '') == '' then return self:inlines(item.children) end
  local keys =
    { desc = desc ~= '' and desc ~= item.href and desc or nil, section = item.section, embed = item.embed and 'true' or nil }
  local opts = { sigil = '@' }
  local text, err = self:build('link', { item.href }, keys, opts)
  if not text and keys.desc then
    -- the description holds something a tag head cannot (a word like `->`): the link keeps its target, the words stay beside it as text
    self:warn('a link description was written as text: ' .. tostring(err))
    keys.desc = nil
    text = self:build('link', { item.href }, keys, opts)
    if text then text = text .. ' ' .. self:text(desc) end
  end
  if not text then
    self:warn('a link could not be written: ' .. tostring(err))
    text = self:text(desc ~= '' and desc or item.href)
  end
  return text
end

---@param items table[]
---@return string
function Writer:inlines(items)
  local out = {}
  for _, item in ipairs(items or {}) do
    local t = item.t
    if t == 'text' then
      out[#out + 1] = self:text(item.s)
    elseif t == 'em' then
      local m = MARKERS[item.kind] or ''
      out[#out + 1] = m .. self:inlines(item.children) .. m
    elseif t == 'code' then
      if item.s:find('`', 1, true) then
        self:warn('inline code with a backquote lost its markup')
        out[#out + 1] = self:text(item.s)
      else
        out[#out + 1] = '`' .. item.s .. '`'
      end
    elseif t == 'link' then
      out[#out + 1] = self:link(item)
    elseif t == 'fnref' then
      out[#out + 1] = self:tag('fn', { item.label }, nil, { sigil = '@' })
    elseif t == 'math' then
      local tex = item.s:gsub('%s*\n%s*', ' ')
      if tex:find('#', 1, true) then
        -- the line tag ends at a hash
        self:warn('inline math with a hash was kept as text')
        out[#out + 1] = self:text('$' .. tex .. '$')
      else
        out[#out + 1] = '#[ math ] ' .. tex .. ' #'
      end
    elseif t == 'date' then
      out[#out + 1] = self:tag('date', { item.value }, { active = item.active == false and 'false' or nil }, { sigil = '@' })
    elseif t == 'label' then
      out[#out + 1] = self:tag('labels', { item.name })
    elseif t == 'br' then
      out[#out + 1] = '\n'
    end
  end
  return table.concat(out)
end

-- blocks --------------------------------------------------------------------------------------------------------------------

local function indent(lines, pad)
  local out = {}
  for _, l in ipairs(lines) do
    out[#out + 1] = l == '' and '' or (pad .. l)
  end
  return out
end

local function width(s) return vim.fn.strdisplaywidth(s) end

---A block tag: the head, and the body indented under it (no closer to write or to forget)
---@param head string the tag without the brackets: `blockquote; class: x`
---@param body string[]
---@return string[]
local function block_tag(head, body)
  local lines = { '[ ' .. head .. ' ]#' }
  for _, l in ipairs(body) do
    lines[#lines + 1] = l == '' and '' or ('   ' .. l)
  end
  return lines
end

---@param self FeyImportWriter
---@param blocks table[]
---@return string[] lines
local function render_blocks(self, blocks)
  local lines = {}
  for i, block in ipairs(blocks or {}) do
    local part = self:block(block)
    if #part > 0 then
      -- the formula tag of a table sits directly under it
      local under = block.t == 'tblfm' and blocks[i - 1] and (blocks[i - 1].t == 'table' or blocks[i - 1].t == 'tblfm')
      if #lines > 0 and not under then lines[#lines + 1] = '' end
      vim.list_extend(lines, part)
    end
  end
  return lines
end

function Writer:blocks(blocks) return render_blocks(self, blocks) end

---@param block table
---@return string[]
function Writer:block(block)
  local t = block.t
  if t == 'paragraph' then
    return vim.split(self:inlines(block.inlines), '\n', { plain = true })
  elseif t == 'list' then
    local lines = {}
    for n, item in ipairs(block.items) do
      local bullet = block.ordered and (tostring(n) .. '.') or '-'
      local box = item.box and ('[' .. item.box .. '] ') or ''
      -- the blocks of an item are apart by a blank line, except a sublist right under the text of the item
      local body, prev = {}, nil
      for _, b in ipairs(item.blocks) do
        local part = self:block(b)
        if #part > 0 then
          if #body > 0 and not (prev and prev.t == 'paragraph' and b.t == 'list') then body[#body + 1] = '' end
          vim.list_extend(body, part)
          prev = b
        end
      end
      local pad = string.rep(' ', #bullet + 2)
      if #body == 0 then body = { '' } end
      body[1] = box .. body[1]
      lines[#lines + 1] = bullet .. '  ' .. body[1]
      for k = 2, #body do
        lines[#lines + 1] = body[k] == '' and '' or (pad .. body[k])
      end
    end
    return lines
  elseif t == 'code' then
    local head = '###  ' .. (block.kind or 'src')
    if block.lang and block.lang ~= '' then head = head .. ' ' .. block.lang end
    if block.args then head = head .. ' ' .. block.args end
    if block.name and not (block.args or ''):find(':name', 1, true) then head = head .. ' :name ' .. block.name end
    local lines = { head }
    for _, l in ipairs(vim.split(block.text, '\n', { plain = true })) do
      -- a line that is the fence itself would end the block; a blank line inside it keeps the indent of whatever holds the block (marked here,
      -- the marker goes in `render`)
      lines[#lines + 1] = l:match('^%s*###%s*$') and (' ' .. l) or l == '' and BLANK or l
    end
    lines[#lines + 1] = '###'
    return lines
  elseif t == 'quote' then
    local name = 'blockquote'
    local body = render_blocks(self, block.blocks)
    if block.title and block.title ~= '' then
      table.insert(body, 1, '!' .. self:text(block.title) .. '!')
      if #body > 1 then table.insert(body, 2, '') end
    end
    local class = block.callout and ('; class: callout callout-' .. block.callout:gsub('[^%w_-]', '')) or ''
    if #body == 0 then body = { '' } end
    return block_tag(name .. class, body)
  elseif t == 'table' then
    local rows, ncols = {}, 0
    local function cells_of(row)
      local cells = {}
      for i, cell in ipairs(row) do
        cells[i] = (self:inlines(cell):gsub('\n', ' '):gsub('|', '\\|'))
      end
      ncols = math.max(ncols, #cells)
      return cells
    end
    local header = block.header and cells_of(block.header)
    for _, row in ipairs(block.rows) do
      rows[#rows + 1] = cells_of(row)
    end
    local all = {}
    if header then all[#all + 1] = header end
    vim.list_extend(all, rows)
    local widths = {}
    for c = 1, ncols do
      widths[c] = 1
      for _, row in ipairs(all) do
        widths[c] = math.max(widths[c], width(row[c] or ''))
      end
    end
    local function line_of(row)
      local parts = {}
      for c = 1, ncols do
        local cell = row[c] or ''
        parts[c] = ' ' .. cell .. string.rep(' ', widths[c] - width(cell)) .. ' '
      end
      return '|' .. table.concat(parts, '|') .. '|'
    end
    local lines = {}
    if header then
      lines[#lines + 1] = line_of(header)
      local rule = {}
      for c = 1, ncols do
        rule[c] = string.rep('=', widths[c] + 2)
      end
      lines[#lines + 1] = '+' .. table.concat(rule, '+') .. '+'
    end
    for _, row in ipairs(rows) do
      lines[#lines + 1] = line_of(row)
    end
    return lines
  elseif t == 'math' then
    return block_tag('math', vim.split(vim.trim(block.s), '\n', { plain = true }))
  elseif t == 'comment' then
    local text = vim.trim(block.s)
    if text == '' then return {} end
    if not text:find('\n', 1, true) and not text:find(' #', 1, true) then return { '#[ comment ] ' .. text .. ' #' } end
    return block_tag('comment', vim.split(text, '\n', { plain = true }))
  elseif t == 'tblfm' then
    -- the formula is the body, so its characters never meet the head
    local text = vim.trim(block.s)
    if text == '' then return {} end
    if not text:find(' #', 1, true) then return { '#[ tblfm ] ' .. text .. ' #' } end
    return block_tag('tblfm', { text })
  elseif t == 'fndef' then
    local body = render_blocks(self, block.blocks)
    if #body == 1 and not body[1]:find(' #', 1, true) and not body[1]:find('^%s*[-#|%[]') then
      return { '#[ fn, ' .. block.label .. ' ] ' .. body[1] .. ' #' }
    end
    return block_tag('fn, ' .. block.label, body)
  end
  return {}
end

-- sections ------------------------------------------------------------------------------------------------------------------

---@param level integer
---@param n integer
---@return string
local function signature_piece(level, n)
  local style = STYLES[math.min(level, #STYLES)]
  return sequences.patterns[style].to_symbol(n) .. '.'
end

---@param section table
---@param path integer[] the counters of the levels so far
---@param lines string[]
function Writer:section(section, path, lines)
  local level = #path
  local pieces = {}
  for l, n in ipairs(path) do
    pieces[l] = signature_piece(l, n)
  end
  local head = { '  ' .. table.concat(pieces) }
  if section.status and (section.status[1] or section.status[2]) then
    local values = {}
    if section.status[1] then values[1] = section.status[1] end
    local keys
    if section.status[2] then
      if section.status[1] then
        values[2] = section.status[2]
      else
        keys = { priority = section.status[2] }
      end
    end
    head[#head + 1] = self:tag(self.names.status, values, keys)
  end
  local title = self:inlines(section.title):gsub('\n', ' ')
  head[#head + 1] = title ~= '' and title or nil
  if section.labels and #section.labels > 0 then head[#head + 1] = self:tag(self.names.labels, section.labels) end
  lines[#lines + 1] = ''
  lines[#lines + 1] = table.concat(head, ' ')

  -- the metadata region: tags on lines of their own, directly under the heading
  local planning = {}
  for _, p in ipairs(section.planning or {}) do
    planning[#planning + 1] = self:tag(
      self.names[p.kind],
      { p.value },
      { active = (p.active ~= nil and p.active ~= (p.kind ~= 'closed')) and tostring(p.active) or nil }
    )
  end
  if #planning > 0 then lines[#lines + 1] = table.concat(planning, ' ') end
  if section.props and #section.props > 0 then
    local keys, order = {}, {}
    for _, kv in ipairs(section.props) do
      if keys[kv[1]] == nil then order[#order + 1] = kv[1] end
      keys[kv[1]] = kv[2]
    end
    lines[#lines + 1] = self:tag(self.names.prop, nil, keys, { order = order })
  end
  if section.clocks and #section.clocks > 0 then
    lines[#lines + 1] = '[ ' .. self.names.logbook .. ' #]'
    -- newest first
    for i = #section.clocks, 1, -1 do
      local c = section.clocks[i]
      lines[#lines + 1] = self:tag(
        self.names.clock,
        { c.start },
        { ['end'] = c['end'], dur = c.dur },
        { order = { 'end', 'dur' } }
      )
    end
    for _, l in ipairs(render_blocks(self, section.logbook or {})) do
      lines[#lines + 1] = l
    end
    lines[#lines + 1] = '[# ' .. self.names.logbook .. ' ]'
  end
  for _, drawer in ipairs(section.drawers or {}) do
    vim.list_extend(lines, block_tag(drawer.name, render_blocks(self, drawer.blocks)))
  end

  local body = render_blocks(self, section.blocks)
  if #body > 0 then
    lines[#lines + 1] = ''
    vim.list_extend(lines, body)
  end
  for i, sub in ipairs(section.sections or {}) do
    local p = vim.list_extend({}, path)
    p[#p + 1] = i
    self:section(sub, p, lines)
  end
end

---Fey text of a document
---@param doc table
---@return string text
---@return string[] warnings
function M.render(doc)
  local config = require('fey.config')
  local self = setmetatable({
    warnings = vim.list_extend({}, doc.warnings or {}),
    names = {
      status = config.fey_status_tag_name or 'status',
      labels = config.fey_labels_tag_name or 'labels',
      prop = config.fey_property_tag_name or 'prop',
      scheduled = config.fey_scheduled_tag_name or 'scheduled',
      deadline = config.fey_deadline_tag_name or 'deadline',
      closed = config.fey_closed_tag_name or 'closed',
      clock = config.fey_clock_tag_name or 'clock',
      logbook = config.fey_logbook_tag_name or 'logbook',
    },
  }, Writer)

  local lines = {}
  if doc.data and #doc.data > 0 then
    local keys, order = {}, {}
    for _, kv in ipairs(doc.data) do
      if keys[kv[1]] == nil then order[#order + 1] = kv[1] end
      keys[kv[1]] = kv[2]
    end
    lines[#lines + 1] = self:tag('table', nil, keys, { order = order })
  end
  if doc.labels and #doc.labels > 0 then lines[#lines + 1] = self:tag(self.names.labels, doc.labels) end
  local body = render_blocks(self, doc.blocks)
  if #body > 0 then
    if #lines > 0 then lines[#lines + 1] = '' end
    vim.list_extend(lines, body)
  end
  for i, section in ipairs(doc.sections or {}) do
    self:section(section, { i }, lines)
  end
  -- a heading is separated from what is above it by one blank line, the file starts with text
  while lines[1] == '' do
    table.remove(lines, 1)
  end
  return (table.concat(lines, '\n'):gsub(BLANK, '')) .. '\n', self.warnings
end

return M
