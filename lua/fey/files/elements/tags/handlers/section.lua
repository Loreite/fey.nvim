-- Handler of `section` tags (name: config.fey_section_tag_name). Applying it jumps to the
-- heading; the tags are kept up to date by fey.links.section.on_reindex, which runs whenever
-- headings are reindexed (text changes, leaving insert mode and before a write).
local M = {}

---@param tag FeyTag
function M.handler(tag) require('fey.links').open_section(tag) end

M.handlers = {
  scope_tag = M.handler,
  line_tag = M.handler,
  block_tag = M.handler,
  pair_tag = M.handler,
}

return M
