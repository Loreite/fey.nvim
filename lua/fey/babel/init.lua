---@class FeyBabel
local Babel = {}
local Tangle = require('fey.babel.tangle')

---Tangle the source blocks of a file
---@param file FeyFile
function Babel.tangle(file) return Tangle:new({ file = file }):tangle() end

---The plan for the blocks of the hollows of a scope (the index, so the files need not be open)
---@param spec? FeyScopeSpec `current` by default
---@param root? string root of the current hollow, by default the one of the active vault
---@return FeyTangleBabel
function Babel.plan_scope(spec, root)
  if not root then
    local vault = require('fey.vault').current()
    root = vault and vault.root
  end
  local rows = require('fey.hollow.scope').blocks(spec, root, { kind = 'src' })
  return Tangle.plan(Tangle.infos_of_rows(rows))
end

---Tangle every source block of the hollows of a scope
---@param spec? FeyScopeSpec
---@param root? string
---@return FeyTangleBabel
function Babel.tangle_scope(spec, root)
  local utils = require('fey.utils')
  local plan = Babel.plan_scope(spec, root)
  local written = Tangle.write(plan)
  for _, p in ipairs(plan.problems) do
    utils.echo_warning(('%s:%d: %s'):format(vim.fn.fnamemodify(p.file, ':~:.'), p.line, p.message))
  end
  utils.echo_info(('Tangled %d blocks into %d files'):format(plan.count, written))
  return plan
end

---Check the blocks of the hollows of a scope without writing: the problems go to the quickfix list
---@param spec? FeyScopeSpec
---@param root? string
---@return FeyTangleProblem[]
function Babel.check(spec, root)
  local plan = Babel.plan_scope(spec, root)
  vim.fn.setqflist(
    vim.tbl_map(
      function(p) return { filename = p.file, lnum = p.line, text = ('%s: %s'):format(p.kind, p.message) } end,
      plan.problems
    ),
    'r'
  )
  vim.fn.setqflist({}, 'a', { title = 'fey tangle check' })
  if #plan.problems == 0 then
    require('fey.utils').echo_info(('Tangle check: %d blocks, no problems'):format(plan.count))
  else
    require('fey.utils').echo_warning(('Tangle check: %d problems'):format(#plan.problems))
    vim.cmd('copen')
  end
  return plan.problems
end

return Babel
