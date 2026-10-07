-- The handler of the `nvim` and `plugin` tags. Both are read and applied by `fey.settings`, which collects the
-- settings of the court, the hollow and the note before it applies any of them; this handler is what the tag
-- itself does (applying only that tag, on top of what is applied).
local M = {}

---@param tag FeyTag
function M.handler(tag)
  local layer = require('fey.settings.layers').read_tag(tag.bufnr, tag.node)
  require('fey.settings').apply(tag.bufnr, { layer = layer })
end

M.handlers = {
  scope_tag = M.handler,
  line_tag = M.handler,
  block_tag = M.handler,
  pair_tag = M.handler,
}

---Start applying settings as the notes change
function M.setup_query() require('fey.settings').setup() end

return M
