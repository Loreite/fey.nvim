-- Handler of `link` tags (name: config.fey_link_tag_name). Applying it follows the link; it is
-- used by the open-at-point mapping.
local M = {}

---@param tag FeyTag
function M.handler(tag) require('fey.links').open_link(tag) end

M.handlers = {
  scope_tag = M.handler,
  line_tag = M.handler,
  block_tag = M.handler,
  pair_tag = M.handler,
}

return M
