-- The court: the top of the tree of hollows, the hollow of `fey_court_dir` (default `~/feyhollow`).
--
-- It is a hollow like any other (its vault is `<fey_court_dir>/.fey/vault.db`, its notes are the files of
-- the directory, and the agenda files live in `<fey_court_dir>/agenda/`), and it is where the hollows meet:
-- a hollow with no hollow above it registers here, with a symbolic link in
-- `<fey_court_dir>/.fey/hollows/`; a hollow inside another hollow registers with that one instead. See
-- `fey.hollow.tree` for the tree, the names and the references (`court:notes:history/a.fey`), and
-- `fey.hollow.scope` for the views over several hollows. The functions here that take no scope read the
-- whole tree:
--
--   local court = require('fey.hollow.court')
--   court.list()                          -- the hollows registered with the court
--   court.dates({ from = t0, to = t1 })   -- dates of all hollows in a range
--   court.jump('court:notes', { cwd = true, tab = true })
local M = {}

local uv = vim.uv

---Name of the court in the tree of hollows
M.NAME = 'court'

local function conf() return require('fey.config') end

---@param path string
---@return string
local function realpath(path) return uv.fs_realpath(path) or vim.fs.normalize(path) end

---Absolute path of the court directory, nil when the court is switched off
---@return string|nil
function M.root()
  local config = conf()
  local options = config.court or {}
  if options.enabled == false then return nil end
  local dir = config.fey_court_dir
  if not dir or dir == '' then return nil end
  return vim.fs.normalize(vim.fn.expand(dir))
end

---Directory of the registrations
---@return string|nil
function M.link_dir()
  local root = M.root()
  return root and vim.fs.joinpath(root, conf().vault.dirname, 'hollows') or nil
end

---Create the directories of the court vault: the Fey files directory with its `.fey` folder (index,
---`dbs`, `hollows`) and the agenda directory.
---@return string|nil root
function M.ensure_dirs()
  local root = M.root()
  if not root then return nil end
  local vault_dir = vim.fs.joinpath(root, conf().vault.dirname)
  local agenda = vim.fs.joinpath(root, (conf().court or {}).agenda_dirname or 'agenda')
  for _, dir in ipairs({ vim.fs.joinpath(vault_dir, 'dbs'), vim.fs.joinpath(vault_dir, 'hollows'), agenda }) do
    if vim.fn.isdirectory(dir) == 0 then vim.fn.mkdir(dir, 'p') end
  end
  return root
end

---The agenda directory of the court
---@return string|nil
function M.agenda_dir()
  local root = M.root()
  return root and vim.fs.joinpath(root, (conf().court or {}).agenda_dirname or 'agenda') or nil
end

---The vault of the court, created on first use (its index is brought up to date by `setup`, not here)
---@return FeyVault|nil
function M.vault()
  local root = M.ensure_dirs()
  if not root then return nil end
  return require('fey.vault').open(root)
end

---@param root string
---@return boolean
function M.is_court(root)
  local court_root = M.root()
  return court_root ~= nil and realpath(root) == realpath(court_root)
end

-- The tree --------------------------------------------------------------------------------

local function tree() return require('fey.hollow.tree') end
local function scope() return require('fey.hollow.scope') end

---The hollows registered with the court (the ones with no hollow above them), ordered by name
---@return FeyHollowEntry[]
function M.list()
  local root = M.root()
  return root and tree().entries(root) or {}
end

---Register a hollow, with the hollow it lives in or else with the court
---@param root string absolute path of the hollow
---@param name? string
---@return string|nil name
---@return string|nil err
function M.register(root, name) return tree().register(root, name) end

---Remove a registration from the court (the hollow itself is not touched)
---@param name string
---@return boolean removed
function M.unregister(name)
  local root = M.root()
  return root ~= nil and tree().unregister(root, name)
end

---Remove the registrations that point at hollows that are gone or belong in another registry, in the
---court and in every hollow below it
---@return string[] removed ids of the registrations
function M.prune()
  local out = {}
  local root = M.root()
  if not root then return out end
  local function walk(registry_root, id)
    for _, name in ipairs(tree().prune(registry_root)) do
      out[#out + 1] = id .. ':' .. name
    end
    for _, entry in ipairs(tree().children(registry_root)) do
      walk(tree().realpath(entry.root), id .. ':' .. entry.name)
    end
  end
  walk(root, M.NAME)
  return out
end

---The hollow that holds a file, opened: the nearest directory at or above it with a hollow folder
---@param path string absolute path
---@return FeyVault|nil
function M.vault_for_path(path)
  local root = tree().hollow_root_of(path)
  return root and require('fey.vault').open(root) or nil
end

-- The merged view -------------------------------------------------------------------------

---@class FeyCourtHollow
---@field id string canonical id, `court`, `court:notes`, `court:notes:history`
---@field root string
---@field vault FeyVault
---@field court boolean the court itself

---@param root string
---@param id string
---@param out FeyCourtHollow[]
local function descend_all(root, id, out)
  for _, entry in ipairs(tree().children(root)) do
    local child_root = tree().realpath(entry.root)
    local child_id = id .. ':' .. entry.name
    local vault = require('fey.vault').open(child_root)
    if vault and vault:open() then
      out[#out + 1] = { id = child_id, root = vault.root, vault = vault, court = false }
      descend_all(child_root, child_id, out)
    end
  end
end

---Every hollow of the tree, the court first, then each hollow below it; opened, not scanned. All of
---them, also the ones that opted out of merged views (see `scope.resolve` for those).
---@return FeyCourtHollow[]
function M.hollows()
  local out = {}
  local court = M.vault()
  if court then
    out[1] = { id = M.NAME, root = court.root, vault = court, court = true }
    descend_all(court.root, M.NAME, out)
  end
  return out
end

---One hollow of the tree by id (`court:notes`); a bare name is a hollow registered with the court
---@param id string
---@return FeyCourtHollow|nil
function M.find(id)
  if not id:match('^court') and not id:match('^current') then id = M.NAME .. ':' .. id end
  local root = tree().resolve_ref(id)
  if not root then return nil end
  local vault = require('fey.vault').open(root)
  if not vault or not vault:open() then return nil end
  return { id = tree().id_of(root) or id, root = vault.root, vault = vault, court = M.is_court(root) }
end

---Absolute path of a file of a hollow of the tree
---@param id string
---@param rel string
---@return string|nil
function M.abs(id, rel)
  local v = M.find(id)
  return v and v.vault:abs(rel) or nil
end

---A number that changes when the index of any hollow changes
---@return integer
function M.revision() return scope().revision('court') end

---Bring the index of every hollow up to date, in the background. The hollows are scanned one after the
---other so a large set does not stall the editor.
---@param on_done? fun()
function M.refresh(on_done)
  local list = M.hollows()
  local i = 0
  local function step()
    i = i + 1
    local v = list[i]
    if not v then
      if on_done then on_done() end
      return
    end
    v.vault:scan({}, function() vim.schedule(step) end)
  end
  step()
end

---Rows of the same read from every hollow of the tree that takes part in merged views, each with `hollow`
---(the id) and, when it has a `path`, `abs`
---@param fn fun(vault: FeyVault): table[]
---@return table[]
function M.collect(fn) return scope().collect('court', nil, fn) end

---A statement run against the index of every hollow, the rows together. It has to stand on its own inside
---one hollow (no joins across hollows).
---@param sql string
---@param params? table
---@return table[]
function M.query(sql, params) return scope().query('court', nil, sql, params) end

---Dates of every hollow, see `FeyVault:dates`; ordered by start
---@param opts? table
---@return table[]
function M.dates(opts) return scope().dates('court', nil, opts) end

---Tasks of every hollow, see `FeyVault:tasks`
---@param opts? table
---@return table[]
function M.tasks(opts) return scope().tasks('court', nil, opts) end

---Labels of every hollow with the number of files using them and the hollows they are in
---@param opts? table see `FeyVault:labels`
---@return { label: string, count: integer, hollows: string[] }[]
function M.labels(opts) return scope().labels('court', nil, opts) end

-- Jumping ---------------------------------------------------------------------------------

---Open a hollow of the tree (by id, `court:notes`, or by the name it has in the court): its directory,
---optionally in a new tab and with the working
---directory set to it (`tcd` in a new tab, `cd` otherwise, which attaches the hollow).
---@param name string
---@param opts? { cwd?: boolean, tab?: boolean } defaults: `court.jump_cwd` (true) and `court.jump_tab` (false)
function M.jump(name, opts)
  local options = conf().court or {}
  opts = opts or {}
  local cwd, tab = opts.cwd, opts.tab
  if cwd == nil then cwd = options.jump_cwd ~= false end
  if tab == nil then tab = options.jump_tab == true end

  local entry = M.find(name)
  if not entry then
    for _, e in ipairs(M.list()) do
      if e.name == name and not e.ok then
        return vim.notify(('fey: the hollow %s is not available (%s)'):format(name, e.root), vim.log.levels.WARN)
      end
    end
    return vim.notify('fey: no hollow named ' .. name, vim.log.levels.WARN)
  end

  if tab then vim.cmd('tabnew') end
  if cwd then vim.cmd((tab and 'tcd ' or 'cd ') .. vim.fn.fnameescape(entry.root)) end
  vim.cmd('edit ' .. vim.fn.fnameescape(entry.root))
end

-- Setup -----------------------------------------------------------------------------------

local setup_done = false

---Create the court and bring its vault, and the vaults of the registered hollows, up to date in the
---background. Commands: `:FeyHollows`, `:FeyHollowsPrune`, `:FeyHollowMerge`.
function M.setup()
  if setup_done then return end
  setup_done = true

  vim.api.nvim_create_user_command('FeyHollows', function(cmd)
    local opts = {}
    for _, arg in ipairs(cmd.fargs) do
      if arg == 'tab' then opts.tab = true end
      if arg == 'cwd' then opts.cwd = true end
      if arg == 'nocwd' then opts.cwd = false end
    end
    require('fey.ui.navigator').hollows(opts)
  end, {
    nargs = '*',
    desc = 'Browse the hollows and jump to one (tab: in a new tab, cwd or nocwd: change the directory or not)',
    complete = function() return { 'tab', 'cwd', 'nocwd' } end,
  })
  vim.api.nvim_create_user_command('FeyHollowsPrune', function()
    local removed = M.prune()
    vim.notify(#removed > 0 and ('fey: removed ' .. table.concat(removed, ', ')) or 'fey: no hollow was gone')
  end, { desc = 'Remove the registrations of hollows that no longer exist (in every hollow)' })

  vim.api.nvim_create_user_command('FeyHollowMerge', function(cmd)
    local current = require('fey.vault').current()
    if not current then return vim.notify('fey: no hollow in the working directory', vim.log.levels.WARN) end
    local settings = tree().settings(current.root)
    local merge
    if cmd.args == 'on' then merge = true elseif cmd.args == 'off' then merge = false else merge = not settings.merge end
    local ok, err = tree().write_settings(current.root, { name = settings.name, merge = merge })
    if not ok then return vim.notify('fey: ' .. tostring(err), vim.log.levels.ERROR) end
    vim.notify(('fey: this hollow is %s the merged views of the hollows above it'):format(merge and 'in' or 'out of'))
  end, {
    nargs = '?',
    desc = 'Take this hollow in or out of the merged views (agenda, court and tree scopes) of the hollows above it',
    complete = function() return { 'on', 'off' } end,
  })

  if not M.root() then return end
  M.ensure_dirs()
  vim.schedule(function()
    local court = M.vault()
    if not court then return end
    court:scan({}, function()
      if (conf().court or {}).refresh_on_start ~= false then vim.schedule(function() M.refresh() end) end
    end)
  end)
end

return M
