-- The `comment` tag: its body is a comment. Every form works. What the body of a tag is, is decided in one place,
-- `Tag.body_node` (`fey.files.elements.tags`): for a scope tag it is the node that holds it, as follows.
--
--   * a line tag `#[ comment ] text #`, a block tag and a pair tag comment their body
--   * a scope tag in a paragraph, a title or a table cell comments that node
--   * a scope tag that is the only content of a list item comments the whole list it is in: this is the only way to
--     comment a list with a scope tag. With other contents (a paragraph, a table, a nested list) it comments the item
--   * a scope tag at the top of a document, with no heading above it, comments the whole file: the exporter
--     (later) has nothing to export, the index skips everything in it. In a section it comments the text of
--     the section, not its subsections
--
-- The body is dimmed with the group `FeyComment`, the style of a comment in code.
local config = require('fey.config')

local M = {}

local ns = vim.api.nvim_create_namespace('fey_tag_comment')
local timers = {}

---The node a comment tag comments: the body of the tag, see `Tag.body_node`
---@param node TSNode a scope_tag, line_tag, block_tag or pair_tag
---@return TSNode|nil
function M.body_node(node) return require('fey.files.elements.tags').body_node(node) end

---Name of a tag node
---@param node TSNode
---@param src integer|string buffer or text
---@return string|nil
local function name_of(node, src)
  local head = node:type() == 'pair_tag' and node:field('open')[1] or node
  local name = head and head:field('name')[1]
  return name and vim.treesitter.get_node_text(name, src) or nil
end

---Is what the comment tag comments indexed. The tag takes an optional boolean, as the first value or the key `index`:
---`{# comment, true #}` keeps indexing it, `{# comment, false #}` ignores it. Without one, `fey_comment_index_default`.
---@param node TSNode
---@param src integer|string buffer or text
---@return boolean
function M.is_indexed(node, src)
  local head = node:type() == 'pair_tag' and node:field('open')[1] or node
  local function bool(text)
    text = vim.trim(text):lower()
    if text == 'true' then return true end
    if text == 'false' then return false end
  end
  for _, kv in ipairs(head:field('key_value')) do
    local key, value = kv:field('key')[1], kv:field('value')[1]
    if key and value and vim.trim(vim.treesitter.get_node_text(key, src)) == 'index' then
      local b = bool(vim.treesitter.get_node_text(value, src))
      if b ~= nil then return b end
    end
  end
  local first = head:field('value')[1]
  local b = first and bool(vim.treesitter.get_node_text(first, src))
  if b ~= nil then return b end
  return config.fey_comment_index_default == true
end

---The bodies of the comment tags of a tree that the index ignores, as byte ranges
---@param root TSNode
---@param src integer|string buffer or text
---@param query vim.treesitter.Query the tags query
---@param name? string tag name, default `fey_comment_tag_name`
---@param all? boolean the comments that are indexed too (an export leaves out all of them)
---@return { node: TSNode, from: integer, to: integer }[]
function M.bodies(root, src, query, name, all)
  name = name or config.fey_comment_tag_name
  local out = {}
  for _, node in query:iter_captures(root, src) do
    if name_of(node, src) == name and (all or not M.is_indexed(node, src)) then
      local body = M.body_node(node)
      if body then
        local _, _, from = body:start()
        local _, _, to = body:end_()
        out[#out + 1] = { node = node, from = from, to = to }
      end
    end
  end
  return out
end

---Is the node inside the body of one of the comments the index ignores, other than a comment tag itself?
---@param node TSNode
---@param bodies { node: TSNode, from: integer, to: integer }[]
---@return boolean
function M.is_commented(node, bodies)
  local _, _, from = node:start()
  local _, _, to = node:end_()
  for _, body in ipairs(bodies) do
    if body.node:id() ~= node:id() and from >= body.from and to <= body.to then return true end
  end
  return false
end

---@param tag FeyTag
function M.handler(tag)
  local body = M.body_node(tag.node)
  if not body then return end
  local srow, scol, erow, ecol = body:range()
  pcall(vim.api.nvim_buf_set_extmark, tag.bufnr, ns, srow, scol, {
    end_row = erow,
    end_col = ecol,
    hl_group = 'FeyComment',
    priority = 150,
  })
end

M.handlers = {
  scope_tag = M.handler,
  line_tag = M.handler,
  block_tag = M.handler,
  pair_tag = M.handler,
}

function M.setup_query(parse_tags)
  vim.api.nvim_set_hl(0, 'FeyComment', { link = 'Comment', default = true })
  local group = vim.api.nvim_create_augroup('FeyTagComment', { clear = true })

  local apply_all = function(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    local tags = parse_tags(bufnr)
    if not tags then return end
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    for _, tag in ipairs(tags) do
      if tag.name == config.fey_comment_tag_name then tag:apply() end
    end
  end

  vim.api.nvim_create_autocmd({ 'FileType', 'BufEnter', 'TextChanged', 'InsertLeave' }, {
    group = group,
    pattern = { 'fey', '*.fey' },
    callback = function(args)
      if timers[args.buf] then timers[args.buf]:stop() end
      timers[args.buf] = vim.defer_fn(function() apply_all(args.buf) end, 300)
    end,
  })
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = group,
    callback = function() vim.api.nvim_set_hl(0, 'FeyComment', { link = 'Comment', default = true }) end,
  })
end

M.ns = ns

return M
