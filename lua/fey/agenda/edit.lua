-- Running an action of a document on an agenda item. The agenda never edits text itself: it opens the file
-- of the item in a window nobody sees, puts the cursor on the heading, runs the same action as the mapping
-- in a document would (`fey_mappings.todo_next_state`, `set_priority`, ...), saves, indexes the file again
-- and gives the result back.
--
--   edit.run(entry, function() return require('fey').action('fey_mappings.set_priority', {}) end)
--
-- A buffer that already has unsaved changes is edited but not written: it stays the user's to save, and the
-- index is updated from the buffer text. A file that was not loaded is loaded for the action and wiped after.
local Promise = require('fey.utils.promise')

local M = {}

---Index a file from what is in its buffer (or from the disk when the buffer is saved)
---@param buf integer
local function reindex(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  local vault = require('fey.vault').for_path(name)
  if not vault then return end
  local path = vim.uv.fs_realpath(name) or name
  if vim.bo[buf].modified then
    vault:index_text(path, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  else
    vault:index_path(path)
  end
end

---@param entry FeyAgendaEntry
---@param action fun(): any a function that may return a promise
---@return FeyPromise result of the action; rejected when it fails
function M.run(entry, action)
  local abs = entry.abs
  if not abs or vim.fn.filereadable(abs) ~= 1 then
    return Promise.reject('The file of this item is not there: ' .. tostring(abs))
  end
  local existing = vim.fn.bufnr(abs)
  local was_loaded = existing > 0 and vim.api.nvim_buf_is_loaded(existing)
  local was_modified = was_loaded and vim.bo[existing].modified or false
  local previous_win = vim.api.nvim_get_current_win()

  local buf = existing > 0 and existing or vim.fn.bufadd(abs)
  vim.fn.bufload(buf)
  if vim.bo[buf].filetype == '' then vim.bo[buf].filetype = 'fey' end
  if not was_loaded then vim.bo[buf].swapfile = false end

  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = 1,
    height = 2,
    row = 99999,
    col = 99999,
    zindex = 1,
    style = 'minimal',
    focusable = false,
    hide = true,
  })
  local line = math.min(entry.line, vim.api.nvim_buf_line_count(buf))
  vim.fn.cursor({ line, 1 })

  local function finish()
    -- close the window first, whatever else goes wrong
    if vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
    if vim.api.nvim_win_is_valid(previous_win) then pcall(vim.api.nvim_set_current_win, previous_win) end
    if not vim.api.nvim_buf_is_valid(buf) then return end
    local ok_write, err_write = pcall(function()
      -- only a buffer the action changed is written, and never one that had unsaved changes before
      if not was_modified and vim.bo[buf].modified then
        vim.api.nvim_buf_call(buf, function() vim.cmd('silent! write') end)
      end
      reindex(buf)
    end)
    if not was_loaded and #vim.fn.win_findbuf(buf) == 0 then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
    if not ok_write then error(err_write, 0) end
  end

  local ok, result = pcall(action)
  if not ok then
    pcall(finish)
    return Promise.reject(result)
  end
  return Promise.resolve(result):next(function(value)
    finish()
    return value
  end, function(err)
    pcall(finish)
    return Promise.reject(err)
  end)
end

return M
