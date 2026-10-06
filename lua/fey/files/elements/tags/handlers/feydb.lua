-- Handler of `feydb` tags (name: config.fey_db_tag_name): imports a database view
-- as a Fey table. Like `query` tags it only runs from the query mappings and when
-- a buffer first loads.
local M = {}

---@param tag FeyTag
function M.handler(tag) require('fey.query').run_tag(tag.bufnr, tag.node) end

M.handlers = {
  scope_tag = M.handler,
  line_tag = M.handler,
  block_tag = M.handler,
  pair_tag = M.handler,
}

return M
