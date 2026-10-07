-- Overdue dates, painted from the index: a deadline of an open task that is before today, and a scheduled date of
-- an open task that is before today. The tree cannot know (it takes the vault, the todo keywords of the file and
-- today), so this is a pass over the buffer with extmarks, run when the file is indexed, when the buffer is
-- entered and when the day may have changed. Switched with `fey_highlight_overdue`.
local config = require('fey.config')

local M = {}

local ns = vim.api.nvim_create_namespace('fey_overdue')
local timers = {}

---@param bufnr integer
---@return FeyVault|nil
local function vault_of(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == '' then return nil end
  local v = require('fey.vault').for_path(name)
  return v and v.db and v or nil
end

---Paint a buffer again
---@param bufnr integer
function M.refresh(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  if not config.fey_highlight_overdue or vim.bo[bufnr].filetype ~= 'fey' then return end
  local vault = vault_of(bufnr)
  if not vault then return end
  local rel = vault:rel_of(vim.api.nvim_buf_get_name(bufnr))
  if not rel then return end
  local today = os.time({ year = tonumber(os.date('%Y')), month = tonumber(os.date('%m')), day = tonumber(os.date('%d')), hour = 0 })
  local edit = require('fey.files.elements.tags.edit')
  local groups = { deadline = '@fey.date.overdue', scheduled = '@fey.date.scheduled_past' }
  for _, row in ipairs(vault:dates({ kinds = { 'deadline', 'scheduled' }, path = rel, open_only = true })) do
    local group = groups[row.kind]
    -- a heading with no keyword has no task to be late with
    if group and (row.active == 1 or row.active == true) and row.start_ts and row.start_ts < today and row.state then
      local tag = edit.at(bufnr, row.line - 1, row.col - 1)
      if tag then
        local sr, sc, er, ec = tag.node:range()
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, sr, sc, { end_row = er, end_col = ec, hl_group = group, priority = 160 })
      end
    end
  end
end

---Paint soon: the day or the index may change several times in a row
---@param bufnr integer
local function schedule(bufnr)
  if timers[bufnr] then timers[bufnr]:stop() end
  timers[bufnr] = vim.defer_fn(function() M.refresh(bufnr) end, 150)
end

function M.setup()
  local group = vim.api.nvim_create_augroup('FeyOverdue', { clear = true })
  vim.api.nvim_create_autocmd({ 'BufEnter', 'FocusGained', 'FileType' }, {
    group = group,
    pattern = { 'fey', '*.fey' },
    callback = function(args) schedule(args.buf) end,
  })
  -- the index of a file changed: the buffers of that file
  vim.api.nvim_create_autocmd('User', {
    group = group,
    pattern = 'FeyVaultFileIndexed',
    callback = function(args)
      local data = args.data or {}
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == 'fey' then
          local v = vault_of(buf)
          if v and v.root == data.root and v:rel_of(vim.api.nvim_buf_get_name(buf)) == data.path then schedule(buf) end
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    callback = function(args) timers[args.buf] = nil end,
  })
end

M.ns = ns

return M
