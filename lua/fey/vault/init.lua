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

---Create a vault in `dir` (default: the cwd): a `.fey/` directory that holds the index and the
---databases. The directory is indexed straight away.
---@param dir? string
---@return FeyVault|nil
function M.init(dir)
  local conf = get_opts()
  dir = realpath(dir or vim.fn.getcwd())
  local vdir = vim.fs.joinpath(dir, conf.dirname)
  local existed = vim.fn.isdirectory(vdir) == 1
  vim.fn.mkdir(vim.fs.joinpath(vdir, 'dbs'), 'p')
  vim.notify(existed and ('fey vault: updating ' .. dir) or ('fey vault: created ' .. vdir))
  return M.attach(dir, {
    on_done = function(stats, err)
      if err then return end
      vim.notify(('fey vault: %d files indexed'):format(stats.total))
    end,
  })
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

  vim.api.nvim_create_autocmd('BufWritePost', {
    group = group,
    pattern = { '*.fey', '*.fey_archive' },
    callback = function(event)
      local path = vim.fn.fnamemodify(event.file, ':p')
      local vault = M.for_path(path)
      if vault then vault:index_path(realpath(path)) end
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
