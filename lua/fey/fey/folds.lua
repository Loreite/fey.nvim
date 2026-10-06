-- Folding of block and pair tags.
--
-- The fold of a tag covers its body only (see the `fey-fold-tag-body!` directive), so that the
-- head, and the closer of a pair tag, stay visible when it is closed. Neovim only toggles a fold
-- from inside it, so these helpers let the fold commands work from the head (and the closer of a
-- pair tag) as well, the way a section can be folded from its heading.
local M = {}

local query

---Rows (0-based, inclusive) of the body that folds, or nil when the tag has nothing to fold
---@param node TSNode block_tag or pair_tag
---@return integer|nil first
---@return integer|nil last
function M.body_range(node)
  local head = node:type() == 'pair_tag' and node:field('open')[1] or node
  local closures = head and head:field('tag_closure') or {}
  local tag_end = closures[#closures]
  if not tag_end then return nil end
  local head_end_row = (tag_end:end_())

  local last
  if node:type() == 'pair_tag' then
    local close = node:field('close')[1]
    if not close then return nil end
    last = (close:start()) - 1
  else
    local body = node:field('body')[1]
    if not body then return nil end
    local er, ec = body:end_()
    last = ec == 0 and er - 1 or er
  end
  if last <= head_end_row then return nil end
  return head_end_row + 1, last
end

---@class FeyFoldTag
---@field first integer first body row (0-based)
---@field last integer last body row
---@field on_head boolean the line is part of the head or is the pair closer

---The innermost block or pair tag with a foldable body that the line belongs to
---@param bufnr integer
---@param lnum integer 1-based
---@return FeyFoldTag|nil
function M.tag_at_line(bufnr, lnum)
  query = query or vim.treesitter.query.parse('fey', '[(block_tag) (pair_tag)] @tag')
  local ok, trees = pcall(function() return vim.treesitter.get_parser(bufnr, 'fey', {}):parse() end)
  if not ok or not trees or not trees[1] then return nil end
  local row = lnum - 1

  local best, best_start
  for _, node in query:iter_captures(trees[1]:root(), bufnr, row, row + 1) do
    local first, last = M.body_range(node)
    if first then
      local sr = node:start()
      local on_head = row >= sr and row < first
      if node:type() == 'pair_tag' then
        local close = node:field('close')[1]
        if close and (close:start()) == row then on_head = true end
      end
      if (on_head or (row >= first and row <= last)) and (not best_start or sr >= best_start) then
        best, best_start = { first = first, last = last, on_head = on_head }, sr
      end
    end
  end
  return best
end

---Run a fold command (`za`, `zo`, `zc`) on the fold of the tag at `tag`, leaving the cursor
---where it was
---@param tag FeyFoldTag
---@param op string
function M.apply(tag, op)
  local cursor = vim.api.nvim_win_get_cursor(0)
  vim.api.nvim_win_set_cursor(0, { tag.first + 1, 0 })
  vim.cmd('silent! normal! ' .. op)
  vim.api.nvim_win_set_cursor(0, cursor)
end

---`za`, `zo` and `zc` that also work on the head and closer of a tag
---@param op string
function M.fold_op(op)
  local bufnr = vim.api.nvim_get_current_buf()
  local tag = M.tag_at_line(bufnr, vim.fn.line('.'))
  if tag and tag.on_head then return M.apply(tag, op) end
  vim.cmd('silent! normal! ' .. (vim.v.count > 0 and vim.v.count or '') .. op)
end

return M
