-- Old names of the Lua API that keep working for a release (III.R): `alias(Heading, 'old_name', 'new_name')` makes `old_name` call
-- `new_name` and say once that the name is old.
local M = {}

---@param class table the class or module
---@param old string
---@param new string
---@param label? string how the old name is shown (`Heading:old_name`)
function M.alias(class, old, new, label)
  class[old] = function(...)
    vim.deprecate(label or old, new, '0.2.0', 'fey.nvim', false)
    return class[new](...)
  end
end

return M
