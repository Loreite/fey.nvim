-- Databases: Obsidian Bases style views over the vault.
--
--   require('fey.db').new()       open a new database showing every note of the vault
--   require('fey.db').pick()      pick an existing database (telescope)
--   require('fey.db').open(name)  open one by name
--
-- Each database is `.fey/dbs/<name>.fey`, written in Fey data serialization.
local M = {}

---@return FeyVault|nil
local function vault()
  local v = require('fey.vault').current()
  if not v then
    vim.notify(
      ('fey db: no hollow here. Run :FeyHollowInit (%s) to create a %s folder in %s'):format(
        '<prefix>vi', require('fey.config').vault.dirname, vim.fn.getcwd()
      ),
      vim.log.levels.WARN
    )
  end
  return v
end

---@return FeyDbOpenMode
local function default_mode() return require('fey.config').vault.db_open_mode or 'vsplit' end

---Open an existing database
---@param name string
---@param mode? FeyDbOpenMode
function M.open(name, mode)
  local v = vault()
  if not v then return end
  return require('fey.db.view').open(v, name, mode or default_mode())
end

---Create a database that shows all notes and open it
---@param mode? FeyDbOpenMode
---@param name? string
function M.new(mode, name)
  local v = vault()
  if not v then return end
  local store = require('fey.db.store')
  local created = store.create(v, name)
  return require('fey.db.view').open(v, created, mode or default_mode())
end

---Pick a database with telescope (falls back to vim.ui.select)
---@param mode? FeyDbOpenMode
function M.pick(mode)
  local v = vault()
  if not v then return end
  local store = require('fey.db.store')
  local list = store.list(v)
  if #list == 0 then
    vim.notify('fey db: no databases yet, create one with the new database mapping', vim.log.levels.INFO)
    return
  end

  local function summary(name)
    local base = store.load(v, name)
    return base and ('%d view%s'):format(#base.views, #base.views == 1 and '' or 's') or 'unreadable'
  end

  local ok_t = pcall(require, 'telescope')
  if not ok_t then
    vim.ui.select(vim.tbl_map(function(e) return e.name end, list), { prompt = 'Fey database' }, function(choice)
      if choice then M.open(choice, mode) end
    end)
    return
  end

  local pickers = require('telescope.pickers')
  local finders = require('telescope.finders')
  local conf = require('telescope.config').values
  local actions = require('telescope.actions')
  local action_state = require('telescope.actions.state')
  local previewers = require('telescope.previewers')

  pickers
    .new({}, {
      prompt_title = 'Fey databases',
      finder = finders.new_table({
        results = list,
        entry_maker = function(e)
          return { value = e.name, ordinal = e.name, display = ('%s  (%s)'):format(e.name, summary(e.name)) }
        end,
      }),
      sorter = conf.generic_sorter({}),
      previewer = previewers.new_buffer_previewer({
        title = 'Definition',
        define_preview = function(self, entry)
          local lines = vim.fn.readfile(store.path(v, entry.value))
          -- plain text on purpose: a `fey` filetype attaches a treesitter highlighter whose
          -- teardown raises errors when telescope deletes the preview buffer
          vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
        end,
      }),
      attach_mappings = function(prompt_bufnr, map)
        local function open_with(open_mode)
          return function()
            local entry = action_state.get_selected_entry()
            actions.close(prompt_bufnr)
            if entry then M.open(entry.value, open_mode) end
          end
        end
        actions.select_default:replace(open_with(mode))
        map({ 'i', 'n' }, '<C-x>', open_with('split'))
        map({ 'i', 'n' }, '<C-v>', open_with('vsplit'))
        map({ 'i', 'n' }, '<C-t>', open_with('tab'))
        map({ 'i', 'n' }, '<C-e>', open_with('current'))
        map({ 'i', 'n' }, '<C-d>', function()
          local entry = action_state.get_selected_entry()
          if entry and vim.fn.confirm('Delete database ' .. entry.value .. '?', '&Yes\n&No', 2) == 1 then
            store.delete(v, entry.value)
            actions.close(prompt_bufnr)
            vim.schedule(function() M.pick(mode) end)
          end
        end)
        return true
      end,
    })
    :find()
end

local setup_done = false

function M.setup()
  if setup_done then return end
  setup_done = true
  vim.api.nvim_create_user_command('FeyHollowInit', function(cmd)
    require('fey.vault').init(nil, { name = cmd.args ~= '' and cmd.args or nil })
  end, {
    nargs = '?',
    desc = 'Make the cwd a hollow (a .fey folder), name it (unique in the hollow above it, or the court), and index it',
  })
  vim.api.nvim_create_user_command('FeyDbHere', function(cmd)
    if cmd.args == '' then return M.pick('current') end
    M.open(cmd.args, 'current')
  end, {
    nargs = '?',
    desc = 'Open a database in the current window (no argument: pick one)',
  })
  vim.api.nvim_create_user_command('FeyDb', function(cmd)
    if cmd.args == '' then return M.pick() end
    M.open(cmd.args)
  end, {
    nargs = '?',
    desc = 'Open a database (no argument: pick one)',
    complete = function()
      local v = require('fey.vault').current()
      if not v then return {} end
      return vim.tbl_map(function(e) return e.name end, require('fey.db.store').list(v))
    end,
  })
  vim.api.nvim_create_user_command('FeyDbNew', function(cmd) M.new(nil, cmd.args ~= '' and cmd.args or nil) end, {
    nargs = '?',
    desc = 'Create a database showing all notes and open it',
  })
end

return M
