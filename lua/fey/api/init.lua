local FeyVault = require('fey.api.vault')

---@class FeyApi
local FeyApi = {}

---The vault that holds a path (default: the current buffer), else the vault of the cwd
---@param path? string
---@return FeyApiVault|nil
function FeyApi.vault(path)
  local registry = require('fey.vault')
  local vault
  if path then
    vault = registry.for_path(path)
  else
    local name = vim.api.nvim_buf_get_name(0)
    vault = (name ~= '' and registry.for_path(name)) or nil
  end
  vault = vault or registry.current()
  return vault and FeyVault._new(vault) or nil
end

---The vault of the cwd (the one the vault module attached on startup or `cd`)
---@return FeyApiVault|nil
function FeyApi.current_vault()
  local vault = require('fey.vault').current()
  return vault and FeyVault._new(vault) or nil
end

---Create a vault (a `.fey` directory) in `dir`, default the cwd, and index it
---@param dir? string
---@return FeyApiVault|nil
function FeyApi.init_vault(dir)
  local vault = require('fey.vault').init(dir)
  return vault and FeyVault._new(vault) or nil
end

---The court, the top of the tree of hollows: the registry of every hollow and the merged view of their vaults
---@return FeyApiCourt
function FeyApi.court() return require('fey.api.court') end

---A file of the current vault by vault relative or absolute path
---@param path string
---@return FeyApiFile|nil
function FeyApi.file(path)
  local vault = FeyApi.vault(path:sub(1, 1) == '/' and path or nil)
  return vault and vault:file(path) or nil
end

---The file of the current buffer
---@return FeyApiFile|nil
function FeyApi.current()
  if vim.bo.filetype ~= 'fey' then error('Not a fey buffer.', 0) end
  local name = vim.api.nvim_buf_get_name(0)
  return FeyApi.file(vim.fn.fnamemodify(name, ':p'))
end

---Run a query (see `FeyApiVault:run_query`) in the current vault
---@param src string
---@param opts? { this?: string, scope?: FeyScopeSpec }
---@return FeyQueryResult
function FeyApi.query(src, opts)
  local vault = FeyApi.vault()
  if not vault then error('No hollow here (run :FeyHollowInit)', 0) end
  return vault:run_query(src, opts)
end

---The Fey source lines a query result is written as (a table or a list)
---@param src string
---@param opts? { this?: string, scope?: FeyScopeSpec }
---@return string[]
function FeyApi.query_lines(src, opts) return require('fey.query.render').lines(FeyApi.query(src, opts)) end

---Subscribe to vault events
---  `indexed`       a scan finished, `data` is `{ root, stats }`
---  `file_indexed`  one file was re-indexed (saved), `data` is `{ root, path }`
---@param event 'indexed'|'file_indexed'
---@param callback fun(data: table)
---@return integer id autocmd id, pass it to `vim.api.nvim_del_autocmd` to unsubscribe
function FeyApi.on(event, callback)
  local pattern = ({ indexed = 'FeyVaultIndexed', file_indexed = 'FeyVaultFileIndexed' })[event]
  if not pattern then error('Unknown event: ' .. tostring(event), 0) end
  return vim.api.nvim_create_autocmd('User', {
    pattern = pattern,
    callback = function(args) callback(args.data or {}) end,
  })
end

---@param s string
local function head_text(s) return (s:gsub('\\', '\\\\'):gsub(',', '\\,'):gsub(';', '\\;')) end

---Text of a link tag: `{@ link, path; desc: Title; section: I.A. @}`
---@param target string path (relative to the vault or the file) or URL
---@param opts? { desc?: string, section?: string }
---@return string
function FeyApi.link_text(target, opts)
  opts = opts or {}
  local parts = { 'link, ', head_text(target) }
  if opts.desc and opts.desc ~= '' then parts[#parts + 1] = '; desc: ' .. head_text(opts.desc) end
  if opts.section and opts.section ~= '' then parts[#parts + 1] = '; section: ' .. head_text(opts.section) end
  return '{@ ' .. table.concat(parts) .. ' @}'
end

---Text of a section tag: `{@ section, I.A., notes/a.fey, 2 @}`
---@param signature string
---@param file? string
---@param n? integer
---@return string
function FeyApi.section_text(signature, file, n)
  local parts = { 'section, ', head_text(signature) }
  if file and file ~= '' then parts[#parts + 1] = ', ' .. head_text(file) end
  if n then
    parts[#parts + 1] = (file and file ~= '') and (', ' .. n) or ('; n: ' .. n)
  end
  return '{@ ' .. table.concat(parts) .. ' @}'
end

---Insert text at the cursor
---@param text string
local function insert_at_cursor(text)
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  vim.api.nvim_buf_set_text(0, row - 1, col, row - 1, col, { text })
  vim.api.nvim_win_set_cursor(0, { row, col + #text })
end

---Insert a link tag to a file at the cursor. A path inside the vault is written relative to the
---vault root.
---@param target string
---@param opts? { desc?: string, section?: string }
function FeyApi.insert_link(target, opts)
  local vault = FeyApi.vault()
  if vault and target:sub(1, 1) == '/' then target = vim.fs.relpath(vault.root, target) or target end
  insert_at_cursor(FeyApi.link_text(target, opts))
end

---Insert a section tag at the cursor
---@param signature string
---@param file? string
---@param n? integer
function FeyApi.insert_section_link(signature, file, n) insert_at_cursor(FeyApi.section_text(signature, file, n)) end

---Follow the link or section tag under the cursor
function FeyApi.follow() require('fey.links').open_at_cursor() end

return FeyApi
