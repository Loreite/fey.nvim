local M = {}

local last_seq_last = {}

function M.get_undotree(buf)
  local ut
  vim.api.nvim_buf_call(buf, function()
    ut = vim.fn.undotree()
  end)
  return ut
end

-- returns true if this change was caused by undo/redo, not a fresh edit
function M.was_undo_or_redo(buf)
  local ut = M.get_undotree(buf)
  local prev_seq_last = last_seq_last[buf]
  last_seq_last[buf] = ut.seq_last

  if prev_seq_last == nil then
    return false -- first observation, nothing to compare against
  end

  return ut.seq_last <= prev_seq_last
end

return M
