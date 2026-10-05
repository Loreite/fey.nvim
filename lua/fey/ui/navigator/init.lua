-- Yazi-style AST navigator for fey buffers.
--
--   require('fey.ui.navigator').open()     -- start at the category list
--   require('fey.ui.navigator').resume()   -- re-open at the last position
--
-- Keys (navigation pane): j/k move, l children, h back, <Tab> local root,
-- <CR> jump, / filter, <C-u>/<C-d> scroll preview, q/<Esc> close.

local config = require('fey.ui.navigator.config')
local model_mod = require('fey.ui.navigator.model')
local state = require('fey.ui.navigator.state')
local view = require('fey.ui.navigator.view')

local M = {}

---@type FeyNavSession|nil
local session = nil

local function notify(msg, level)
  vim.notify('Fey navigator: ' .. msg, level or vim.log.levels.INFO, { title = 'Fey' })
end

local global_group
local function ensure_global_autocmds()
  if global_group then
    return
  end
  global_group = vim.api.nvim_create_augroup('FeyNavigatorState', { clear = true })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = global_group,
    callback = function(ev)
      state.clear(ev.buf)
    end,
  })
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = global_group,
    callback = view.define_highlights,
  })
end

---@class FeyNavOpenOpts
---@field bufnr? integer   source buffer (default: current)
---@field resume? boolean  restore the last navigation state

---@param opts? FeyNavOpenOpts
function M.open(opts)
  opts = opts or {}
  ensure_global_autocmds()
  if session and not session.closed then
    session:close()
  end

  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  if bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  local model, err = model_mod.new(bufnr)
  if not model then
    return notify(err or 'unavailable', vim.log.levels.WARN)
  end

  local resume = opts.resume
  if resume == nil then
    resume = config.options.resume_by_default
  end

  local stack
  if resume then
    local saved = state.get(bufnr)
    local info
    stack, info = state.restore(model, saved)
    if saved and saved.changedtick ~= model.changedtick then
      if info.dropped > 0 then
        notify('document changed; restored the nearest valid parent')
      elseif info.fuzzy then
        notify('document changed; restored the closest matching object')
      end
    end
  else
    stack = state.fresh(model)
  end

  session = view.open(model, stack, {
    src_win = vim.api.nvim_get_current_win(),
    on_close = function(s)
      if session == s then
        session = nil
      end
    end,
  })
  return session
end

--- Re-open at the last navigation state for the buffer.
---@param opts? FeyNavOpenOpts
function M.resume(opts)
  return M.open(vim.tbl_extend('force', opts or {}, { resume = true }))
end

function M.close()
  if session then
    session:close()
  end
end

function M.toggle(opts)
  if session and not session.closed then
    return M.close()
  end
  return M.open(opts)
end

--- Forget the saved position for a buffer.
function M.reset(bufnr)
  state.clear(bufnr or vim.api.nvim_get_current_buf())
end

---@return FeyNavSession|nil
function M.session()
  return session
end

---@param opts? table  see fey.ui.navigator.config
function M.setup(opts)
  config.set(opts)
  ensure_global_autocmds()
  vim.api.nvim_create_user_command('FeyNavigate', function(cmd)
    local arg = cmd.fargs[1]
    if arg == 'resume' then
      M.resume()
    elseif arg == 'reset' then
      M.reset()
    elseif arg == 'close' then
      M.close()
    else
      M.open()
    end
  end, {
    nargs = '?',
    desc = 'Fey: AST navigator',
    complete = function()
      return { 'open', 'resume', 'reset', 'close' }
    end,
  })
end

return M
