-- Vault: an Obsidian-like metadata index for Fey notes.
--
-- When the cwd contains a `.fey/` directory, every Fey file below it is parsed
-- and its metadata (document data, headings, tags, links, labels) is cached in
-- `.fey/vault.db`. The index is refreshed on startup, when the cwd changes and
-- when a Fey file inside the vault is saved. See `fey.vault.vault` for the schema.
--
--   local vault = require('fey.vault').current()
--   vault:files_with_label('design')
--   vault:backlinks('notes/a.fey', 'I.A.')
--   vault:query('SELECT path FROM files WHERE title LIKE :t', { t = '%fey%' })
--
-- Events (`User` autocmds): `FeyVaultIndexed` once a scan finished and
-- `FeyVaultFileIndexed` after a single file was re-indexed on save.
local Vault = require('fey.vault.vault')

local M = {}

---@type table<string, FeyVault>
local vaults = {}
---@type FeyVault|nil
local active
local setup_done = false
local warned = false

---@return FeyVaultOpts
local function get_opts() return require('fey.config').vault end

---@param path string
---@return string
local function realpath(path) return vim.uv.fs_realpath(path) or vim.fs.normalize(path) end

---The vault of the active directory, if it has one
---@return FeyVault|nil
function M.current() return active end

---All vaults opened in this session
---@return table<string, FeyVault>
function M.all() return vaults end

---@param path string absolute path
---@return FeyVault|nil vault whose root contains `path`
function M.for_path(path)
  path = realpath(path)
  local best
  for root, vault in pairs(vaults) do
    if (path == root or vim.startswith(path, root .. '/')) and (not best or #root > #best.root) then best = vault end
  end
  return best
end

---The vault of a hollow, opened but not made active and not scanned. For the hollows of the court, which
---keep their own vault. Nil when `root` is not a hollow.
---@param root string
---@return FeyVault|nil
function M.open(root)
  local conf = get_opts()
  if not conf then return nil end
  root = realpath(root)
  local vault = vaults[root]
  if vault then return vault end
  if vim.fn.isdirectory(vim.fs.joinpath(root, conf.dirname)) == 0 then return nil end
  vault = Vault.new(root, conf)
  vaults[root] = vault
  return vault
end

---Make `dir` the active vault when it contains a vault directory, and update its index.
---@param dir? string defaults to the cwd
---@param opts? { full?: boolean, on_done?: fun(stats: FeyVaultScanStats|nil, err: string|nil) }
---@return FeyVault|nil
function M.attach(dir, opts)
  opts = opts or {}
  local conf = get_opts()
  if not conf or not conf.enabled then return nil end

  dir = realpath(dir or vim.fn.getcwd())
  if vim.fn.isdirectory(vim.fs.joinpath(dir, conf.dirname)) == 0 then
    active = nil
    return nil
  end

  local vault = vaults[dir]
  if not vault then
    vault = Vault.new(dir, conf)
    vaults[dir] = vault
  end
  active = vault
  -- every hollow is registered with the hollow it lives in, or with the court: the tree of hollows
  pcall(function() require('fey.hollow.tree').register_chain(dir) end)

  vault:scan({ full = opts.full }, function(stats, err)
    if err and not warned then
      warned = true
      vim.notify('fey vault: ' .. err, vim.log.levels.WARN)
    end
    if opts.on_done then opts.on_done(stats, err) end
  end)
  return vault
end

---Re-scan the active vault (`full` rebuilds the index from scratch)
---@param full? boolean
function M.reindex(full)
  if not active then
    vim.notify('fey vault: no ' .. get_opts().dirname .. ' directory in ' .. vim.fn.getcwd(), vim.log.levels.WARN)
    return
  end
  M.attach(active.root, {
    full = full,
    on_done = function(stats, err)
      if err then return end
      vim.notify(
        ('fey vault: %d files, %d indexed, %d removed, %d failed'):format(
          stats.total,
          stats.indexed,
          stats.removed,
          stats.failed
        )
      )
    end,
  })
end

---Make `dir` (default: the cwd) a hollow: a `.fey/` folder that holds its vault and its databases. The
---directory is indexed straight away. A new hollow gets a name that is unique in the registry it belongs to
---(the hollow it lives in, else the court): `opts.name`, or the user is asked (the directory name is the
---default). The name is kept in `.fey/hollow.fey`, so the id of the hollow stays the same.
---@param dir? string
---@param opts? { name?: string }
---@return FeyVault|nil
function M.init(dir, opts)
  opts = opts or {}
  local conf = get_opts()
  local tree = require('fey.hollow.tree')
  local court = require('fey.hollow.court')
  dir = realpath(dir or vim.fn.getcwd())
  local vdir = vim.fs.joinpath(dir, conf.dirname)
  local existed = vim.fn.isdirectory(vdir) == 1
  vim.fn.mkdir(vim.fs.joinpath(vdir, 'dbs'), 'p')

  local function finish()
    vim.notify(existed and ('fey hollow: updating ' .. dir) or ('fey hollow: created ' .. vdir))
    return M.attach(dir, {
      on_done = function(stats, err)
        if err then return end
        vim.notify(('fey hollow: %d files indexed'):format(stats.total))
      end,
    })
  end

  local registry_root = tree.registry_root_for(dir)
  if registry_root and court.is_court(registry_root) then court.ensure_dirs() end
  local settings = tree.settings(dir)
  local registered = registry_root and tree.name_in(registry_root, dir)

  local function save(name)
    local ok, err = tree.write_settings(dir, { name = name, merge = settings.merge })
    if not ok then vim.notify('fey hollow: cannot save the name: ' .. tostring(err), vim.log.levels.WARN) end
  end

  if opts.name then
    local ok, err = true, nil
    if registry_root and registered ~= opts.name then ok, err = tree.valid_name(registry_root, opts.name) end
    if not ok then return vim.notify('fey hollow: ' .. err, vim.log.levels.ERROR) end
    save(opts.name)
    return finish()
  end

  if not registry_root or registered or settings.name then return finish() end

  local where = tree.id_of(registry_root) or registry_root
  local function ask(default, problem)
    vim.ui.input({
      prompt = ('Name of the hollow in %s%s: '):format(where, problem and (' (' .. problem .. ')') or ''),
      default = default,
    }, function(input)
      if input == nil then return finish() end -- cancelled: the directory name is used
      input = vim.trim(input)
      local ok, err = tree.valid_name(registry_root, input)
      if not ok then return ask(input, err) end
      save(input)
      finish()
    end)
  end
  ask(vim.fs.basename(dir):gsub('[^%w_.%-]', '_'))
end

function M.setup()
  if setup_done then return end
  setup_done = true

  local group = vim.api.nvim_create_augroup('fey_vault', { clear = true })

  vim.api.nvim_create_autocmd('DirChanged', {
    group = group,
    pattern = '*',
    callback = function() M.attach() end,
  })

  ---The vault that indexes a file: one this session has open, or a registered one
  ---@param path string
  ---@return FeyVault|nil
  local function vault_of(path)
    return M.for_path(path) or require('fey.hollow.court').vault_for_path(path)
  end

  vim.api.nvim_create_autocmd('BufWritePost', {
    group = group,
    pattern = { '*.fey', '*.fey_archive' },
    callback = function(event)
      local path = vim.fn.fnamemodify(event.file, ':p')
      local vault = vault_of(path)
      if vault then vault:index_path(realpath(path)) end
    end,
  })

  -- Edited buffers are indexed after a short pause, so an agenda or a database shows what was typed
  -- without a save. A buffer back at its saved state, or gone with unsaved changes, is indexed from the disk.
  local live_timers = {}
  local function live_index(buf)
    live_timers[buf] = nil
    if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_buf_is_loaded(buf) then return end
    local name = vim.api.nvim_buf_get_name(buf)
    if name == '' then return end
    local path = realpath(name)
    local vault = vault_of(path)
    if not vault then return end
    if vim.bo[buf].modified then
      vault:index_text(path, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    else
      vault:index_path(path)
    end
  end

  vim.api.nvim_create_autocmd({ 'TextChanged', 'InsertLeave' }, {
    group = group,
    pattern = { '*.fey', '*.fey_archive' },
    callback = function(event)
      local conf = get_opts()
      if not conf or not conf.live_index then return end
      local buf = event.buf
      if live_timers[buf] then live_timers[buf]:stop() end
      live_timers[buf] = vim.defer_fn(function() live_index(buf) end, 300)
    end,
  })

  vim.api.nvim_create_autocmd('BufUnload', {
    group = group,
    pattern = { '*.fey', '*.fey_archive' },
    callback = function(event)
      if not vim.bo[event.buf].modified then return end
      local name = vim.api.nvim_buf_get_name(event.buf)
      local vault = name ~= '' and vault_of(realpath(name))
      if vault then vault:index_path(realpath(name)) end
    end,
  })

  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = group,
    callback = function()
      for _, vault in pairs(vaults) do
        vault:close()
      end
    end,
  })

  vim.api.nvim_create_user_command(
    'FeyVaultReindex',
    function(cmd) M.reindex(cmd.bang) end,
    { bang = true, desc = 'Update the fey vault index (! rebuilds it from scratch)' }
  )

  -- startup: Fey.setup() may run before or after VimEnter, so don't wait for it.
  -- Deferred so the first scan never delays the UI.
  vim.schedule(function() M.attach() end)
end

return M
