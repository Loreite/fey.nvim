-- Broken links: the links and section tags of the hollows of a scope that lead nowhere, in the quickfix list.
-- A query on the index (`FeyVault:broken_links`), so no file needs to be open.
local M = {}

local MESSAGE = {
  file = 'no such file',
  section = 'the file has no such heading',
  id = 'nothing has this id',
}

---The broken links of a scope, with the absolute path of their file
---@param spec? FeyScopeSpec
---@param root? string root of the current hollow
---@return table[]
function M.collect(spec, root)
  if not root then
    local vault = require('fey.vault').current()
    root = vault and vault.root
  end
  return require('fey.hollow.scope').collect(spec, root, function(vault) return vault:broken_links() end)
end

---Put the broken links of a scope in the quickfix list
---@param spec? FeyScopeSpec
---@param root? string
---@return table[]
function M.run(spec, root)
  local rows = M.collect(spec, root)
  vim.fn.setqflist({}, ' ', {
    title = 'fey broken links',
    items = vim.tbl_map(
      function(r) return { filename = r.abs, lnum = r.line, text = ('%s %s: %s'):format(r.kind, r.target, MESSAGE[r.reason]) } end,
      rows
    ),
  })
  if #rows == 0 then
    require('fey.utils').echo_info('No broken links')
  else
    require('fey.utils').echo_warning(('%d broken links'):format(#rows))
    vim.cmd('copen')
  end
  return rows
end

return M
