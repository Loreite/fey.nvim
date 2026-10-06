local FeyFile = require('fey.api.file')

---@class FeyApiVault
---@field root string absolute path of the folder that holds the `.fey` directory
---@field dir string absolute path of the `.fey` directory
---@field private _vault FeyVault
local FeyVault = {}
FeyVault.__index = FeyVault

---@private
---@param vault FeyVault
---@return FeyApiVault
function FeyVault._new(vault)
  return setmetatable({ root = vault.root, dir = vault.dir, _vault = vault }, FeyVault)
end

---@return 'idle'|'indexing'|'ready'|'error'
function FeyVault:state() return self._vault.state end

---Counter that changes whenever the index changes: a cache key for anything derived from it
---@return integer
function FeyVault:revision() return self._vault.revision or 0 end

---Block until the index is ready
---@param timeout? integer milliseconds, default 10000
---@return boolean ready
function FeyVault:wait(timeout)
  return vim.wait(timeout or 10000, function() return self._vault.state == 'ready' end, 10)
end

---Update the index: new and changed files are parsed, deleted ones dropped
---@param opts? { full?: boolean } `full` rebuilds the index from scratch
---@param on_done? fun(stats: FeyVaultScanStats|nil, err: string|nil)
function FeyVault:reindex(opts, on_done) self._vault:scan(opts, on_done) end

---(Re)index one file now, e.g. after writing it from outside the editor
---@param path string absolute path
---@return boolean indexed
function FeyVault:index_path(path) return self._vault:index_path(path) end

---Run a SQL query against the index (see the schema in `fey.vault.vault`)
---@param sql string
---@param params? table named (`:name`) parameters
---@return table[] rows
function FeyVault:query(sql, params) return self._vault:query(sql, params) end

---@param path string vault relative path
---@return table[]
function FeyVault:headings(path) return self._vault:headings(path) end

---@param path string
---@return table[]
function FeyVault:links(path) return self._vault:links(path) end

---Links and section tags that point at a file, or at one of its headings
---@param path string vault relative path
---@param signature? string heading signature (delimiters are ignored)
---@return table[]
function FeyVault:backlinks(path, signature) return self._vault:backlinks(path, signature) end

---Every file of the vault, ordered by path (the lazy fields of a file load on first use)
---@return FeyApiFile[]
function FeyVault:files()
  local out = {}
  for i, row in ipairs(self._vault:query('SELECT path, title, mtime, size, errors FROM files ORDER BY path')) do
    out[i] = FeyFile._new(self, row)
  end
  return out
end

---One file by vault relative or absolute path
---@param path string
---@return FeyApiFile|nil
function FeyVault:file(path)
  if path:sub(1, 1) == '/' then path = vim.fs.relpath(self.root, vim.uv.fs_realpath(path) or path) or path end
  local row = self._vault:query('SELECT path, title, mtime, size, errors FROM files WHERE path = :p', { p = path })[1]
  return row and FeyFile._new(self, row) or nil
end

---Files that have a label (case insensitive, `a` also matches `a/b`)
---@param label string
---@return FeyApiFile[]
function FeyVault:files_with_label(label)
  local rows = self._vault:query(
    [[SELECT DISTINCT f.path, f.title, f.mtime, f.size, f.errors FROM files f JOIN labels l ON l.file_id = f.id
      WHERE l.label = :l OR l.label LIKE :p ESCAPE '\' ORDER BY f.path]],
    { l = label, p = label:gsub('[%%_\\]', '\\%0') .. '/%' }
  )
  return vim.tbl_map(function(r) return FeyFile._new(self, r) end, rows)
end

---Files whose document data has a property, optionally with a given value
---@param name string
---@param value? any compared with the stored value
---@return FeyApiFile[]
function FeyVault:files_with_property(name, value)
  local out = {}
  for _, hit in ipairs(self._vault:files_with_property(name, value)) do
    out[#out + 1] = self:file(hit.path)
  end
  return out
end

---All labels with the number of files that use them
---@param opts? { level?: 'file'|'heading', container?: string } see `Vault:labels`
---@return { label: string, count: integer }[]
function FeyVault:labels(opts) return self._vault:labels(opts) end

---Every use of a syntactic tag name (`path`, `line`, `vals`, `attrs` decoded)
---@param name string
---@return table[]
function FeyVault:tags(name) return self._vault:tags(name) end

---Names of the databases in `.fey/dbs`
---@return string[]
function FeyVault:databases()
  return vim.tbl_map(function(e) return e.name end, require('fey.db.store').list(self._vault))
end

---Run a query-language query (the `TABLE`/`LIST` language of `query` tags)
---@param src string
---@param opts? { this?: string } vault relative path of the note the query lives in
---@return FeyQueryResult result `type`, `count`, and `headers`/`rows` (TABLE) or `items` (LIST)
function FeyVault:run_query(src, opts)
  opts = opts or {}
  local this
  if opts.this then this = require('fey.query.pages').store(self._vault):page(opts.this) end
  return require('fey.query.engine').run(self._vault, src, { this = this })
end

---Rows of a database view, computed like the view shows them
---@param name string database name (file name in `.fey/dbs` without `.fey`)
---@param view? string view name, the first view when omitted
---@return { columns: string[], props: string[], rows: any[][], total: integer }
function FeyVault:database(name, view)
  local store = require('fey.db.store')
  local Model = require('fey.db.model')
  local base, err = store.load(self._vault, name)
  if not base then error(err, 0) end
  local selected = base.views[1]
  if view then
    selected = nil
    for _, v in ipairs(base.views) do
      if v.name:lower() == view:lower() then selected = v end
    end
    if not selected then error(('database %s has no view named %s'):format(name, view), 0) end
  end
  local model = Model.new(self._vault, base)
  local result = model:compute(selected)
  if result.error then error(result.error, 0) end

  local columns, props, getters = {}, {}, {}
  for _, col in ipairs(selected.columns) do
    columns[#columns + 1] = (col.display and col.display ~= '') and col.display or col.prop
    props[#props + 1] = col.prop
    getters[#getters + 1] = model:getter(col.prop)
  end
  local rows = {}
  for i, row in ipairs(result.rows) do
    local cells = {}
    for c, get in ipairs(getters) do
      cells[c] = get(row)
    end
    rows[i] = cells
  end
  return { columns = columns, props = props, rows = rows, total = result.total }
end

return FeyVault
