-- Handler of `query` tags (name: config.fey_query_tag_name). Unlike the `hl` and
-- `nvim` handlers it is never applied automatically: it only runs from the query
-- mappings (`fey.query.run_at_cursor` / `run_all`).
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
