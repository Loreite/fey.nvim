-- Where in a tag the cursor is, from the text of the line before it (the buffer has parse errors while a tag is being
-- typed, so the tree cannot say).
--
--   {# sta|              name       base `sta`
--   {# status, TO|       value      tag `status`, index 1
--   {# status, TODO, |   value      index 2
--   {# date, 2026; ac|   key        tag `date`
--   {# link, a.fey; section: I|   key_value   key `section`
--
-- The same for the other forms: `#[ name, value; key: v ]`, `[ name ... ]#`, `[ name ... #]`. Values are separated by
-- `,`, the keys start after the first `;` and are separated by `;`; a backslash escapes a character.
local M = {}

---@class FeyTagContext
---@field kind 'name'|'value'|'key'|'key_value'
---@field tag? string name of the tag
---@field index? integer for a value, which one (1 based)
---@field key? string for a key_value, the key
---@field values string[] the values before the cursor, trimmed
---@field base string the text typed of what is completed
---@field start integer 0 based byte offset in the line where `base` starts

---The start of the text of the last tag that is still open at the end of the line
---@param line string
---@return integer|nil from 1 based index of the first character of the head text (after the opener and blanks)
local function open_head(line)
  local best
  local function consider(from, closed_by)
    -- the text after the opener; closed when the closer is in it
    local rest = line:sub(from)
    if closed_by and rest:find(closed_by) then return end
    if not best or from > best then best = from end
  end
  for _, e in line:gmatch('(){[#@]%s*()') do consider(e, '[#@]}') end
  for _, e in line:gmatch('()#%[%s*()') do consider(e, '%]') end
  -- `[ name` of a block and a pair tag; `[#` is a closer
  for s, e in line:gmatch('()%[ %s*()') do
    if line:sub(s - 1, s - 1) ~= '#' and line:sub(s + 1, s + 1) ~= '#' then consider(e, '%]') end
  end
  return best
end

---Split text at the delimiter outside of escapes
---@param text string
---@param delimiter string one character
---@return string[] parts
---@return integer[] starts 1 based index of the start of each part
local function split(text, delimiter)
  local parts, starts, acc, from = {}, {}, {}, 1
  local i = 1
  while i <= #text do
    local c = text:sub(i, i)
    if c == '\\' then
      acc[#acc + 1] = text:sub(i, i + 1)
      i = i + 2
    elseif c == delimiter then
      parts[#parts + 1], starts[#starts + 1] = table.concat(acc), from
      acc, from = {}, i + 1
      i = i + 1
    else
      acc[#acc + 1] = c
      i = i + 1
    end
  end
  parts[#parts + 1], starts[#starts + 1] = table.concat(acc), from
  return parts, starts
end

---@param line string the text before the cursor
---@return FeyTagContext|nil
function M.parse(line)
  local from = open_head(line)
  if not from then return nil end
  local head = line:sub(from)

  -- the name, while nothing follows it
  local word = head:match('^[%w_]*$')
  if word then return { kind = 'name', values = {}, base = word, start = from - 1 } end
  local name = head:match('^([%w_]+)')
  if not name then return nil end
  local rest_from = from + #name
  local rest = head:sub(#name + 1)

  local sections, section_starts = split(rest, ';')
  if #sections == 1 then
    -- values: `, a, b`
    local parts, starts = split(rest, ',')
    local values = {}
    for i = 2, #parts - 1 do
      values[#values + 1] = vim.trim(parts[i])
    end
    local last = parts[#parts]
    if #parts == 1 then
      -- the name is followed by blanks only: no value has begun
      if not rest:match('^%s*$') then return nil end
      return { kind = 'value', tag = name, index = 1, values = {}, base = '', start = rest_from + #rest - 1 }
    end
    local lead = #last:match('^%s*')
    return {
      kind = 'value',
      tag = name,
      index = #parts - 1,
      values = values,
      base = last:sub(lead + 1),
      start = rest_from - 1 + starts[#parts] - 1 + lead,
    }
  end

  -- values before the first `;`
  local values = {}
  do
    local parts = split(sections[1], ',')
    for i = 2, #parts do
      values[#values + 1] = vim.trim(parts[i])
    end
  end
  local last = sections[#sections]
  local lead = #last:match('^%s*')
  local text = last:sub(lead + 1)
  local base_start = rest_from - 1 + section_starts[#sections] - 1 + lead
  local key, value = text:match('^([%w_%-]+)%s*:%s*(.*)$')
  if key then
    local value_lead = #text:match('^[%w_%-]+%s*:%s*')
    return { kind = 'key_value', tag = name, key = key, values = values, base = value, start = base_start + value_lead }
  end
  if text:match('^[%w_%-]*$') then
    return { kind = 'key', tag = name, values = values, base = text, start = base_start }
  end
  return nil
end

return M
