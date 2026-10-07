-- The generated parts of the docs: a part is the lines between two markers in a `.fey` file, made by a function of the code, so it cannot drift
-- (the same as the list of mappings in the README). `scripts/gen_docs.lua` writes them, `tests/docs.lua` checks them.
local M = {}

---@param name string
---@return string begin
---@return string end_
function M.markers(name)
  -- comment tags: an export leaves them out, and they are not indexed
  return ('#[ comment ] begin generated: %s (scripts/gen_docs.lua) #'):format(name), ('#[ comment ] end generated: %s #'):format(name)
end

---Replace the generated part of a file
---@param lines string[]
---@param name string
---@param body string[] what goes between the markers
---@return string[]|nil new
---@return string|nil err
function M.replace(lines, name, body)
  local begin_marker, end_marker = M.markers(name)
  local from, to
  for i, line in ipairs(lines) do
    if line == begin_marker then from = i end
    if line == end_marker then to = i end
  end
  if not from or not to or to < from then return nil, ('the markers of "%s" are not in the file'):format(name) end
  local out = vim.list_slice(lines, 1, from)
  out[#out + 1] = ''
  vim.list_extend(out, body)
  out[#out + 1] = ''
  vim.list_extend(out, vim.list_slice(lines, to))
  return out
end

---A Fey table
---@param rows string[][]
---@param headers string[]
---@return string[]
function M.table(rows, headers) return require('fey.docs.mappings').table_lines(rows, headers) end

---Text that goes in a cell or a line of prose: the syntax of a tag in it would be a tag
---@param s string
---@return string
function M.prose(s)
  s = s:gsub('{[#@].-[#@]}', 'a tag'):gsub('[\r\n]+', ' ')
  return s
end

return M
