-- Write a property value back into the Fey file it came from.
--
-- A top level property of a document lives in one of these places, and edits keep
-- its shape:
--   * an attribute in the head of a `table` tag:    {# table; rating: 4 #}
--   * a keyed bullet in the body of a `table` tag:   rating_:  4   (scalars, sublists, inline arrays)
--   * a section of its own with a `value` tag:       "  I. rating" + {# value, 4 #}
-- A property that exists nowhere yet is appended to the first `table` tag head
-- (scalars) or written as a new `[ table #]` block at the top of the file.
local extract = require('fey.vault.extract')
local serialize = require('fey.db.serialize')
local constants = require('fey.utils.constants')

local M = {}

---@param s string
local function trim(s) return (s:gsub('^%s+', ''):gsub('%s+$', '')) end

-- Input and value formatting ------------------------------------------------------------

---Turn text typed into a cell into a value (nil clears the property)
---@param text string
---@param ptype? string property type
---@return any
function M.parse_input(text, ptype)
  text = trim(text)
  if text == '' then return nil end
  if ptype == 'list' or text:match('^%[.*%]$') then
    local inner = text:match('^%[(.*)%]$') or text
    local out = {}
    for part in inner:gmatch('[^,]+') do
      part = trim(part)
      if part ~= '' then out[#out + 1] = extract.scalar(part) end
    end
    return out
  end
  if ptype == 'string' then return (text:match('^"(.*)"$') or text:match("^'(.*)'$") or text) end
  if ptype == 'number' then return tonumber(text) or text end
  if ptype == 'boolean' then
    local l = text:lower()
    if l == 'true' or l == 'yes' or l == 'y' or l == '1' then return true end
    if l == 'false' or l == 'no' or l == 'n' or l == '0' then return false end
  end
  return extract.scalar(text)
end

---Text of a value in a tag head (`,` `;` and `\` escaped)
---@param v any
---@return string|nil text
---@return string|nil err
local function attr_text(v)
  local t = type(v)
  if t == 'boolean' then return tostring(v) end
  if t == 'number' then return (v % 1 == 0 and ('%d'):format(v)) or ('%.14g'):format(v) end
  if t ~= 'string' then return nil, 'only simple values fit in a tag head' end
  if v:find('[\r\n]') then return nil, 'multi-line text does not fit in a tag head' end
  if v:find('%s[%p][%]})>]') or v:find('^[%]})>]') then return nil, 'text looks like a tag closer' end
  local text = v
  if extract.scalar(v) ~= v or v:find('^%s') or v:find('%s$') then text = '"' .. v .. '"' end
  return (text:gsub('\\', '\\\\'):gsub(',', '\\,'):gsub(';', '\\;'))
end

---@param v any
---@return string|nil text
---@return string|nil err
local function inline_text(v)
  local s = serialize.scalar_inline(v)
  if not s then return nil, 'this text needs a fenced block' end
  return s
end

-- Positions --------------------------------------------------------------------------------

---@param src string
---@return integer[] offsets byte offset (1-based) at which each row starts
local function row_offsets(src)
  local offs, pos = { 1 }, 1
  while true do
    local nl = src:find('\n', pos, true)
    if not nl then break end
    offs[#offs + 1] = nl + 1
    pos = nl + 1
  end
  return offs
end

---Column (0-based) of a byte offset
---@param src string
---@param pos integer
local function col_at(src, pos)
  local before = src:sub(1, pos - 1)
  local nl = before:match('.*()\n')
  return nl and (pos - nl - 1) or (pos - 1)
end

---@class FeyDbEdit
---@field s integer 1-based first byte
---@field e integer 1-based byte after the replaced span
---@field text string

---Range of a node without surrounding whitespace, as byte offsets
---@param node TSNode
---@param src string
---@param offs integer[]
---@return integer s, integer e
local function span(node, src, offs)
  local sr, sc, er, ec = node:range()
  local s, e = offs[sr + 1] + sc, offs[er + 1] + ec
  while s < e and src:sub(s, s):match('%s') do s = s + 1 end
  while e > s and src:sub(e - 1, e - 1):match('%s') do e = e - 1 end
  return s, e
end

---@param node TSNode
---@return string
local function name_of(node, src)
  local head = node:type() == 'pair_tag' and node:field('open')[1] or node
  local n = head and head:field('name')[1]
  return n and vim.treesitter.get_node_text(n, src) or ''
end

---@param bullet TSNode
---@param src string
local function bullet_key(bullet, src)
  local segment = bullet:named_child(0)
  if not segment then return nil end
  local index = vim.treesitter.get_node_text(segment, src):match('^([%w_]*).$') or ''
  local anon = index:match(constants.segment_enumeration)
  if not anon then return nil end
  local key = anon:sub(1, -2)
  return key ~= '' and key or nil
end

---@param head TSNode
---@param src string
---@return TSNode|nil
local function head_end(head)
  local closures = head:field('tag_closure')
  return closures[#closures]
end

-- Finding a property ---------------------------------------------------------------------------

---@class FeyDbLocation
---@field kind 'attr'|'bullet'|'section'
---@field node TSNode
---@field extra? any

---@param root TSNode
---@param src string
---@param key string
---@return FeyDbLocation|nil loc
---@return TSNode|nil insert_head first table tag head available for appending an attribute
local function locate(root, src, key)
  local body = root:field('body')[1]
  local insert_head
  if body then
    for _, child in ipairs(body:named_children()) do
      local t = child:type()
      if (t == 'scope_tag' or t == 'block_tag' or t == 'pair_tag' or t == 'line_tag') and name_of(child, src) == 'table' then
        local head = t == 'pair_tag' and child:field('open')[1] or child
        insert_head = insert_head or head
        for _, kv in ipairs(head:field('key_value')) do
          local k = kv:field('key')[1]
          if k and trim(vim.treesitter.get_node_text(k, src)) == key then return { kind = 'attr', node = kv }, insert_head end
        end
        local tbody = (t == 'pair_tag' or t == 'block_tag') and child:field('body')[1]
        if tbody then
          for _, l in ipairs(tbody:named_children()) do
            if l:type() == 'list' then
              for _, item in ipairs(l:named_children()) do
                if item:type() == 'listitem' then
                  local bullet = item:field('bullet')[1]
                  if bullet and bullet_key(bullet, src) == key then return { kind = 'bullet', node = item }, insert_head end
                end
              end
            end
          end
        end
      end
    end
  end
  for _, section in ipairs(root:field('subsection')) do
    local heading = section:field('heading')[1]
    local title = heading and heading:field('title')[1]
    if title and trim(vim.treesitter.get_node_text(title, src)) == key then return { kind = 'section', node = section }, insert_head end
  end
  return nil, insert_head
end

---@param item TSNode listitem
---@param src string
---@param offs integer[]
---@param value any
---@return FeyDbEdit[]|nil, string|nil
local function edit_bullet(item, src, offs, value)
  local contents = vim.tbl_filter(function(n) return n:named() end, item:field('contents'))
  local bullet = item:field('bullet')[1]
  local is_list = type(value) == 'table'

  if value == nil then
    -- the last entry of a `[ table #]` block takes the whole block with it
    local list = item:parent()
    local body = list and list:parent()
    local tag = body and body:parent()
    if list and #list:named_children() == 1 and tag and tag:type() == 'pair_tag' and #body:named_children() == 1 then
      local tsr = tag:start()
      local _, _, ter, tec = tag:range()
      local last_row = tec == 0 and ter - 1 or ter
      local stop = offs[last_row + 2] or (#src + 1) -- start of the line after the closer
      return { { s = offs[tsr + 1], e = stop, text = '' } }
    end
    -- remove the whole item
    local s, e = span(item, src, offs)
    local sr = item:start()
    return { { s = offs[sr + 1], e = e + (src:sub(e, e) == '\n' and 1 or 0), text = '' } }
  end

  if #contents == 0 then
    local _, be = span(bullet, src, offs)
    if is_list then
      local indent = (' '):rep(col_at(src, (span(bullet, src, offs))) + 4)
      local lines = {}
      for _, v in ipairs(value) do
        local t = inline_text(v)
        if not t then return nil, 'list items must be short text' end
        lines[#lines + 1] = indent .. '-  ' .. t
      end
      return { { s = be, e = be, text = '\n' .. table.concat(lines, '\n') } }
    end
    local t, err = inline_text(value)
    if not t then return nil, err end
    return { { s = be, e = be, text = '  ' .. t } }
  end

  local first = contents[1]
  if #contents > 1 then return nil, 'this property has a shape that cannot be edited here' end

  if first:type() == 'paragraph' then
    local only_tag
    local named = {}
    for child in first:iter_children() do
      if child:named() then named[#named + 1] = child end
    end
    if #named == 1 and named[1]:type() == 'scope_tag' then only_tag = named[1] end
    if only_tag then
      if not is_list then return nil, 'this property holds an array tag; enter a list' end
      local parts = {}
      for _, v in ipairs(value) do
        local t, err = attr_text(v)
        if not t then return nil, err end
        parts[#parts + 1] = t
      end
      local sigil = vim.treesitter.get_node_text(only_tag, src):sub(2, 2)
      local open = vim.treesitter.get_node_text(only_tag, src):sub(1, 1)
      local close = ({ ['['] = ']', ['{'] = '}', ['('] = ')', ['<'] = '>' })[open]
      local text = ('%s%s array%s %s%s%s'):format(open, sigil, #parts > 0 and (', ' .. table.concat(parts, ', ')) or '', sigil, close, '')
      local s, e = span(only_tag, src, offs)
      return { { s = s, e = e, text = text } }
    end
    if is_list then return nil, 'this property holds a single value; remove it first to enter a list' end
    local t, err = inline_text(value)
    if not t then return nil, err end
    local s, e = span(first, src, offs)
    return { { s = s, e = e, text = t } }
  end

  if first:type() == 'list' then
    if not is_list then return nil, 'this property holds a list; enter a comma separated list' end
    local indent = (' '):rep(col_at(src, (span(first, src, offs))))
    local lines = {}
    for i, v in ipairs(value) do
      local t, err = inline_text(v)
      if not t then return nil, err end
      lines[i] = (i == 1 and '' or indent) .. '-  ' .. t
    end
    local s, e = span(first, src, offs)
    return { { s = s, e = e, text = table.concat(lines, '\n') } }
  end
  return nil, 'this property has a shape that cannot be edited here'
end

---Compute the byte edits that set `key` to `value` (nil removes it)
---@param src string
---@param key string
---@param value any
---@return FeyDbEdit[]|nil edits
---@return string|nil err
function M.plan(src, key, value)
  local root = vim.treesitter.get_string_parser(src, 'fey'):parse()[1]:root()
  local offs = row_offsets(src)
  local loc, insert_head = locate(root, src, key)

  if loc then
    if loc.kind == 'attr' then
      local kv = loc.node
      if value == nil then
        local delim = kv:prev_sibling()
        local ds = delim and select(1, span(delim, src, offs)) or span(kv, src, offs)
        local _, e = span(kv, src, offs)
        return { { s = ds, e = e, text = '' } }
      end
      local text, err = attr_text(value)
      if not text then return nil, err end
      local v = kv:field('value')[1]
      local s, e = span(v, src, offs)
      return { { s = s, e = e, text = text } }
    elseif loc.kind == 'bullet' then
      return edit_bullet(loc.node, src, offs, value)
    else
      -- section: only `{# value, x #}` bodies
      local body = loc.node:field('body')[1]
      local tags = {}
      if body then
        for _, c in ipairs(body:named_children()) do
          if (c:type() == 'scope_tag' or c:type() == 'line_tag' or c:type() == 'block_tag' or c:type() == 'pair_tag') and name_of(c, src) == 'value' then
            tags[#tags + 1] = c
          end
        end
      end
      if #tags ~= 1 or value == nil or type(value) == 'table' then return nil, 'this section cannot be edited here' end
      local head = tags[1]:type() == 'pair_tag' and tags[1]:field('open')[1] or tags[1]
      local v = head:field('value')[1]
      if not v then return nil, 'this section cannot be edited here' end
      local text, err = attr_text(value)
      if not text then return nil, err end
      local s, e = span(v, src, offs)
      return { { s = s, e = e, text = text } }
    end
  end

  if value == nil then return {} end -- nothing to clear

  -- a new property
  if type(value) ~= 'table' and insert_head then
    local text = attr_text(value)
    if text then
      local closer = head_end(insert_head)
      if closer then
        local sr, sc = closer:range()
        return { { s = offs[sr + 1] + sc, e = offs[sr + 1] + sc, text = ('; %s: %s'):format(key, text) } }
      end
    end
  end
  local lines = { '[ table #]' }
  vim.list_extend(lines, serialize.entry_lines(key, value))
  lines[#lines + 1] = '[# table ]'
  lines[#lines + 1] = ''
  return { { s = 1, e = 1, text = table.concat(lines, '\n') .. '\n' } }
end

---@param src string
---@param edits FeyDbEdit[]
---@return string
function M.apply(src, edits)
  table.sort(edits, function(a, b) return a.s > b.s end)
  for _, e in ipairs(edits) do
    src = src:sub(1, e.s - 1) .. e.text .. src:sub(e.e)
  end
  return src
end

---Apply edits (byte offsets into `src`) to a file, through its buffer when it is loaded.
---An unmodified buffer is written, a modified one is left modified for the user to save.
---@param vault FeyVault|nil
---@param abs string
---@param src string text the edits were planned against
---@param edits FeyDbEdit[]
---@param bufnr? integer loaded buffer of the file
---@return boolean ok
---@return string|nil err
function M.commit(vault, abs, src, edits, bufnr)
  if #edits == 0 then return true end
  bufnr = bufnr or vim.fn.bufnr(abs)
  local loaded = bufnr > 0 and vim.api.nvim_buf_is_loaded(bufnr)

  if loaded then
    local was_modified = vim.bo[bufnr].modified
    local offs = row_offsets(src)
    ---@param pos integer
    local function position(pos)
      local lo, hi = 1, #offs
      while lo < hi do
        local mid = math.ceil((lo + hi) / 2)
        if offs[mid] <= pos then lo = mid else hi = mid - 1 end
      end
      return lo - 1, pos - offs[lo]
    end
    table.sort(edits, function(a, b) return a.s > b.s end)
    for _, e in ipairs(edits) do
      local r1, c1 = position(e.s)
      local r2, c2 = position(e.e)
      vim.api.nvim_buf_set_text(bufnr, r1, c1, r2, c2, vim.split(e.text, '\n', { plain = true }))
    end
    if not was_modified then
      vim.api.nvim_buf_call(bufnr, function() vim.cmd('silent! noautocmd write') end)
      if vault then vault:index_path(abs) end
    end
    return true
  end

  local new_src = M.apply(src, edits)
  local tmp = abs .. '.feytmp'
  local fh, werr = io.open(tmp, 'wb')
  if not fh then return false, werr end
  fh:write(new_src)
  fh:close()
  local renamed, rerr = os.rename(tmp, abs)
  if not renamed then return false, rerr end
  if vault then vault:index_path(abs) end
  return true
end

---Set (or clear with nil) a property of a note and keep the index in step
---@param vault FeyVault
---@param rel string path of the note relative to the vault root
---@param key string
---@param value any
---@return boolean ok
---@return string|nil err
function M.set(vault, rel, key, value)
  local abs = vault:abs(rel)
  local bufnr = vim.fn.bufnr(abs)
  local loaded = bufnr > 0 and vim.api.nvim_buf_is_loaded(bufnr)

  local src
  if loaded then
    src = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
    if vim.bo[bufnr].endofline then src = src .. '\n' end
  else
    local fh = io.open(abs, 'rb')
    if not fh then return false, 'cannot read ' .. rel end
    src = fh:read('*a')
    fh:close()
  end

  local ok, edits, err = pcall(M.plan, src, key, value)
  if not ok then return false, tostring(edits) end
  if not edits then return false, err end
  return M.commit(vault, abs, src, edits, loaded and bufnr or nil)
end

M.span = span
M.row_offsets = row_offsets

return M
