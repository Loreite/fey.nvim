-- The table of checkbox states for the README, made from `fey.files.elements.checkbox` so it cannot drift.
--
--   nvim -l scripts/gen_mappings.lua          writes this and the list of mappings
local Checkbox = require('fey.files.elements.checkbox')

local M = {}

M.BEGIN = '-- begin generated: checkbox states (scripts/gen_mappings.lua) --'
M.END = '-- end generated: checkbox states --'

---@return string[]
function M.render()
  local rows = {}
  for _, state in ipairs(Checkbox.STATES) do
    if state.mark ~= 'X' then
      local box = state.mark == 'x' and '`[x]` `[X]`' or ('`[%s]`'):format(state.mark)
      rows[#rows + 1] = { box, state.name, state.class, state.unicode, ('U+%04X'):format(state.nerd) }
    end
  end
  local out = { M.BEGIN, '' }
  vim.list_extend(out, require('fey.docs.mappings').table_lines(rows, { 'mark', 'name', 'counts as', 'icon', 'Nerd Font' }))
  out[#out + 1] = ''
  out[#out + 1] = M.END
  return out
end

---@param lines string[]
---@return string[]|nil
---@return string|nil err
function M.replace(lines)
  local first, last
  for i, l in ipairs(lines) do
    if l == M.BEGIN then first = i end
    if l == M.END then last = i end
  end
  if not first or not last or last < first then return nil, 'the checkbox markers are not in the file' end
  local out = vim.list_slice(lines, 1, first - 1)
  vim.list_extend(out, M.render())
  vim.list_extend(out, vim.list_slice(lines, last + 1))
  return out
end

return M
