-- Database files: `.fey/dbs/<name>.fey`, one per database, in Fey data serialization.
local serialize = require('fey.db.serialize')

local M = {}

---@param vault FeyVault
---@return string
function M.dir(vault) return vim.fs.joinpath(vault.dir, 'dbs') end

---@param vault FeyVault
---@param name string
function M.path(vault, name) return vim.fs.joinpath(M.dir(vault), name .. '.fey') end

---File name safe version of a database name
---@param name string
function M.sanitize(name)
  name = vim.trim((name:gsub('[/\\:%*%?"<>|%c]', '-')))
  return name ~= '' and name or 'database'
end

---@param vault FeyVault
---@return { name: string, mtime: integer }[]
function M.list(vault)
  local out = {}
  local dir = M.dir(vault)
  if vim.fn.isdirectory(dir) == 0 then return out end
  for name, kind in vim.fs.dir(dir) do
    if kind == 'file' and name:match('%.fey$') then
      local stat = vim.uv.fs_stat(vim.fs.joinpath(dir, name))
      out[#out + 1] = { name = name:gsub('%.fey$', ''), mtime = stat and stat.mtime.sec or 0 }
    end
  end
  table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
  return out
end

---@return table view
function M.default_view(name)
  return {
    name = name or 'Table',
    type = 'table',
    columns = {
      { prop = 'file.name' },
      { prop = 'file.folder' },
      { prop = 'file.mtime' },
      { prop = 'file.labels' },
    },
    sort = { { prop = 'file.name', dir = 'asc' } },
    row_height = 1,
    freeze = 1,
  }
end

---@param name string
---@return table base
function M.default_base(name)
  return { name = name, version = 1, views = { M.default_view('Table') } }
end

---Make a decoded base safe to use: missing lists become empty, views always exist
---@param base table
---@param name string
---@return table
function M.normalize(base, name)
  base.name = base.name or name
  base.version = base.version or 1
  base.formulas = type(base.formulas) == 'table' and base.formulas or {}
  base.properties = type(base.properties) == 'table' and base.properties or {}
  base.views = type(base.views) == 'table' and base.views or {}
  if #base.views == 0 then base.views[1] = M.default_view('Table') end

  local function group(g)
    if type(g) ~= 'table' then return nil end
    if g.kind ~= 'group' then return g end
    g.mode = g.mode or 'and'
    g.items = type(g.items) == 'table' and g.items or {}
    for i, item in ipairs(g.items) do
      g.items[i] = group(item)
    end
    return g
  end
  base.filters = group(base.filters)
  for _, view in ipairs(base.views) do
    view.type = view.type or 'table'
    view.name = view.name or 'View'
    view.columns = type(view.columns) == 'table' and view.columns or {}
    view.sort = type(view.sort) == 'table' and view.sort or {}
    view.filters = group(view.filters)
    view.row_height = tonumber(view.row_height) or 1
    view.freeze = tonumber(view.freeze) or 1
    if type(view.group) ~= 'table' or not view.group.prop then view.group = nil end
  end
  return base
end

---@param vault FeyVault
---@param name string
---@return table|nil base
---@return string|nil err
function M.load(vault, name)
  local path = M.path(vault, name)
  local fh = io.open(path, 'rb')
  if not fh then return nil, 'no such database: ' .. name end
  local src = fh:read('*a')
  fh:close()
  local ok, data, errors = pcall(serialize.decode, src)
  if not ok then return nil, tostring(data) end
  if not data then return nil, 'unreadable database file: ' .. (errors and errors[1] or '') end
  return M.normalize(data, name)
end

---@param vault FeyVault
---@param name string
---@param base table
---@return boolean ok
---@return string|nil err
function M.save(vault, name, base)
  vim.fn.mkdir(M.dir(vault), 'p')
  local ok, text = pcall(serialize.encode, base)
  if not ok then return false, tostring(text) end
  local path = M.path(vault, name)
  local tmp = path .. '.tmp'
  local fh, err = io.open(tmp, 'wb')
  if not fh then return false, err end
  fh:write(text)
  fh:close()
  local renamed, rerr = os.rename(tmp, path)
  if not renamed then return false, rerr end
  return true
end

---Create a database with a free name
---@param vault FeyVault
---@param wanted? string
---@return string name
---@return table base
function M.create(vault, wanted)
  local base_name = M.sanitize(wanted or 'database')
  local name, n = base_name, 1
  while vim.uv.fs_stat(M.path(vault, name)) do
    n = n + 1
    name = ('%s-%d'):format(base_name, n)
  end
  local base = M.default_base(name)
  assert(M.save(vault, name, base))
  return name, base
end

---@param vault FeyVault
---@param old string
---@param new string
---@return boolean ok
---@return string|nil err
function M.rename(vault, old, new)
  new = M.sanitize(new)
  if vim.uv.fs_stat(M.path(vault, new)) then return false, 'a database named ' .. new .. ' exists' end
  local ok, err = os.rename(M.path(vault, old), M.path(vault, new))
  return ok ~= nil, err
end

---@param vault FeyVault
---@param name string
function M.delete(vault, name) return os.remove(M.path(vault, name)) end

return M
