-- Yazi-style navigator: the objects of a fey buffer, the directories of its hollow, the hollows.
--
--   require('fey.ui.navigator').open()      -- the document of the buffer, at the category list
--   require('fey.ui.navigator').resume()    -- re-open at the last position
--   require('fey.ui.navigator').hollows()   -- start in the list of hollows, at the hollow of the buffer
--
-- Keys (navigation pane): j/k move, l open, h up (out of a document into its directory, up the
-- directories to the root of the hollow, then through the hollows above it up to the court), <Tab> local
-- root, <CR> jump (to the object, the file, or the hollow), <C-t> jump in a new tab, H hollows only, /
-- filter, <C-u>/<C-d> scroll preview, q/<Esc> close. A thin pane on the left lists the level above.

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
---@field level? 'hollows' start in the list of hollows instead of a document
---@field cwd? boolean     jumping to a hollow changes the working directory (default `court.jump_cwd`)
---@field tab? boolean     jumping to a hollow opens it in a new tab (default `court.jump_tab`)

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
  local view_opts = {
    src_win = vim.api.nvim_get_current_win(),
    jump_opts = { cwd = opts.cwd, tab = opts.tab },
    on_close = function(s)
      if session == s then
        session = nil
      end
    end,
  }

  local levels = require('fey.ui.navigator.levels')
  local name = vim.api.nvim_buf_get_name(bufnr)
  if opts.level == 'hollows' then
    view_opts.loc, view_opts.select = levels.hollow_level_for(name ~= '' and name or nil)
    session = view.open(nil, nil, view_opts)
    return session
  end

  -- a buffer that is not a Fey file is no document: start among the files of its directory
  if name ~= '' and not require('fey.utils').is_fey_file(name) then
    view_opts.loc, view_opts.select = { kind = 'dir', path = levels.dir_of_buffer(bufnr) or vim.fn.getcwd() }, name
    session = view.open(nil, nil, view_opts)
    return session
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

  session = view.open(model, stack, view_opts)
  return session
end

--- Re-open at the last navigation state for the buffer.
---@param opts? FeyNavOpenOpts
function M.resume(opts)
  return M.open(vim.tbl_extend('force', opts or {}, { resume = true }))
end

--- Open the list of hollows, at the hollow of the current buffer (the court when it is in none).
---@param opts? { cwd?: boolean, tab?: boolean }
function M.hollows(opts)
  return M.open(vim.tbl_extend('force', opts or {}, { level = 'hollows' }))
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
    if arg == 'hollows' then
      M.hollows()
    elseif arg == 'resume' then
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
      return { 'open', 'resume', 'hollows', 'reset', 'close' }
    end,
  })
end

return M
