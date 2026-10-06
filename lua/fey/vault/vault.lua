-- A vault is a directory containing a `.fey/` folder. The folder holds a SQLite
-- database (`vault.db`) with the metadata of every Fey file below the vault root,
-- so other code can search and query the notes without parsing them again.
--
-- Tables (all `path` columns are relative to the vault root):
--
--   files       id, path, mtime (ms), size, title, data (JSON), errors (JSON), indexed_at
--   headings    file_id, ord, parent_ord, level, signature, title, path, line, end_line, data (JSON)
--   tags        file_id, heading_ord, kind, name, line, vals (JSON list), attrs (JSON map)
--   links       file_id, heading_ord, kind, target, target_file, target_sig, description, line, meta (JSON)
--   labels      file_id, heading_ord, label
--   properties  file_id, name, value (JSON): top level keys of the document data
--
-- `heading_ord` is NULL for document level entries. `links.target_file` and
-- `links.target_sig` hold the resolved destination, so the backlinks of a file or
-- section are a single indexed lookup (see `Vault:backlinks`).
local Db = require('fey.vault.db')
local extract = require('fey.vault.extract')
local fs = require('fey.utils.fs')
local uv = vim.uv

local SCHEMA_VERSION = 1

local SCHEMA = [[
CREATE TABLE files (
  id INTEGER PRIMARY KEY,
  path TEXT NOT NULL UNIQUE,
  mtime INTEGER NOT NULL,
  size INTEGER NOT NULL,
  title TEXT,
  data TEXT,
  errors TEXT,
  indexed_at INTEGER
);
CREATE TABLE headings (
  id INTEGER PRIMARY KEY,
  file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
  ord INTEGER NOT NULL,
  parent_ord INTEGER,
  level INTEGER NOT NULL,
  signature TEXT,
  title TEXT,
  path TEXT,
  line INTEGER,
  end_line INTEGER,
  data TEXT
);
CREATE INDEX headings_file ON headings(file_id, ord);
CREATE INDEX headings_title ON headings(title COLLATE NOCASE);
CREATE TABLE tags (
  id INTEGER PRIMARY KEY,
  file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
  heading_ord INTEGER,
  kind TEXT NOT NULL,
  name TEXT NOT NULL,
  line INTEGER,
  vals TEXT,
  attrs TEXT
);
CREATE INDEX tags_file ON tags(file_id);
CREATE INDEX tags_name ON tags(name);
CREATE TABLE links (
  id INTEGER PRIMARY KEY,
  file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
  heading_ord INTEGER,
  kind TEXT NOT NULL,
  target TEXT NOT NULL,
  target_file TEXT,
  target_sig TEXT,
  description TEXT,
  line INTEGER,
  meta TEXT
);
CREATE INDEX links_file ON links(file_id);
CREATE INDEX links_target ON links(target_file, target_sig);
CREATE TABLE labels (
  file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
  heading_ord INTEGER,
  label TEXT NOT NULL COLLATE NOCASE
);
CREATE INDEX labels_label ON labels(label);
CREATE INDEX labels_file ON labels(file_id);
CREATE TABLE properties (
  file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  value TEXT
);
CREATE INDEX properties_name ON properties(name, file_id);
]]

local TABLES = { 'properties', 'labels', 'links', 'tags', 'headings', 'files' }

---@class FeyVaultOpts
---@field dirname string name of the vault directory. Default '.fey'
---@field db_name string database file inside `dirname`. Default 'vault.db'
---@field ignore string[] names of directories/files never indexed
---@field label_tags string[] tag names whose values are labels
---@field link_tags string[] tag names that point to another file or section
---@field time_budget_ms integer how long one indexing slice may block the editor

---@class FeyVaultScanStats
---@field total integer files found
---@field indexed integer files (re)parsed
---@field removed integer files dropped from the index
---@field failed integer files that could not be read or parsed

---@class FeyVault
---@field root string
---@field dir string
---@field db_path string
---@field opts FeyVaultOpts
---@field db? FeyVaultDb
---@field state 'idle'|'indexing'|'ready'|'error'
---@field last_error? string
---@field stats? FeyVaultScanStats
---@field revision? integer bumped on every change of the index (cache key for consumers)
---@field private gen integer
local Vault = {}
Vault.__index = Vault

---@param root string absolute path of the directory that contains the vault folder
---@param opts FeyVaultOpts
---@return FeyVault
function Vault.new(root, opts)
  local dir = vim.fs.joinpath(root, opts.dirname)
  return setmetatable({
    root = root,
    dir = dir,
    db_path = vim.fs.joinpath(dir, opts.db_name),
    opts = opts,
    state = 'idle',
    gen = 0,
  }, Vault)
end

---@param value any
---@return string|nil
local function encode(value)
  if value == nil then return nil end
  return vim.json.encode(value)
end

---An empty Lua table encodes as `[]`, which is wrong for maps
---@param map table
local function encode_map(map)
  if next(map) == nil then return '{}' end
  return vim.json.encode(map)
end

---@param map table
local function as_map(map) return next(map) == nil and vim.empty_dict() or map end

---@param s string|nil
---@return any
local function decode(s)
  if s == nil then return nil end
  local ok, value = pcall(vim.json.decode, s, { luanil = { object = true, array = true } })
  return ok and value or nil
end

-- Database ------------------------------------------------------------------

---@return boolean ok
---@return string|nil err
function Vault:open()
  if self.db then return true end
  if vim.fn.isdirectory(self.dir) == 0 then return false, self.dir .. ' does not exist' end
  local db, err = Db.open(self.db_path)
  if not db then
    self.state, self.last_error = 'error', err
    return false, err
  end
  db:exec('PRAGMA foreign_keys = ON')
  db:exec('PRAGMA journal_mode = WAL')
  db:exec('PRAGMA synchronous = NORMAL')

  local version = db:run('PRAGMA user_version')[1].user_version
  if version ~= SCHEMA_VERSION then
    -- the index is a cache: rebuild instead of migrating
    db:transaction(function()
      for _, t in ipairs(TABLES) do
        db:exec('DROP TABLE IF EXISTS ' .. t)
      end
      db:exec(SCHEMA)
      db:exec(('PRAGMA user_version = %d'):format(SCHEMA_VERSION))
    end)
  end
  self.db = db
  return true
end

function Vault:close()
  self.gen = self.gen + 1 -- cancels a running scan
  if self.db then self.db:close() end
  self.db = nil
  self.state = 'idle'
end

-- Indexing ------------------------------------------------------------------

---Resolve the file a link points to, relative to the vault root
---@param src_rel string
---@param target string
---@return string|nil
function Vault:_resolve_file(src_rel, target)
  if target == '' or target:match('^%a[%w+.-]*:') then return nil end
  local path
  if target:sub(1, 1) == '/' then
    path = vim.fs.relpath(self.root, target)
  elseif target:match('^%.%.?/') then
    path = vim.fs.normalize(vim.fs.joinpath(vim.fs.dirname(src_rel), target))
  else
    path = vim.fs.normalize(target)
  end
  if not path or path:match('^%.%./') or path == '..' then return nil end
  return (path:gsub('^%./', ''))
end

---Store the metadata of one file, replacing what was stored before
---@param rel string
---@param entry { mtime: integer, size: integer }
---@param meta FeyVaultFileMeta|nil nil when the file could not be read or parsed
---@param errors string[]
function Vault:_store(rel, entry, meta, errors)
  local db = assert(self.db)
  self.revision = (self.revision or 0) + 1
  db:run('DELETE FROM files WHERE path = :path', { path = rel })
  db:run(
    [[INSERT INTO files(path, mtime, size, title, data, errors, indexed_at)
      VALUES(:path, :mtime, :size, :title, :data, :errors, :now)]],
    {
      path = rel,
      mtime = entry.mtime,
      size = entry.size,
      title = meta and meta.title ~= '' and meta.title or vim.fn.fnamemodify(rel, ':t:r'),
      data = meta and encode(meta.data) or nil,
      errors = #errors > 0 and encode(errors) or nil,
      now = os.time(),
    }
  )
  if not meta then return end
  local file_id = db:last_insert_rowid()

  for _, h in ipairs(meta.headings) do
    db:run(
      [[INSERT INTO headings(file_id, ord, parent_ord, level, signature, title, path, line, end_line, data)
        VALUES(:file_id, :ord, :parent_ord, :level, :signature, :title, :path, :line, :end_line, :data)]],
      {
        file_id = file_id,
        ord = h.ord,
        parent_ord = h.parent_ord,
        level = h.level,
        signature = h.signature,
        title = h.title,
        path = h.path,
        line = h.line,
        end_line = h.end_line,
        data = encode(h.data),
      }
    )
  end

  for _, t in ipairs(meta.tags) do
    db:run(
      [[INSERT INTO tags(file_id, heading_ord, kind, name, line, vals, attrs)
        VALUES(:file_id, :heading_ord, :kind, :name, :line, :vals, :attrs)]],
      {
        file_id = file_id,
        heading_ord = t.heading_ord,
        kind = t.kind,
        name = t.name,
        line = t.line,
        vals = encode(t.values),
        attrs = encode_map(t.attrs),
      }
    )
  end

  for _, l in ipairs(meta.links) do
    local target_file, target_sig
    if l.kind == 'section' then
      -- {@ section, signature, file, N @}: only the tokens of the signature identify a heading
      local file = l.values[2] or l.attrs.file
      if file and file:match('^%-?%d+$') and not l.values[3] and not l.attrs.file then file = nil end
      target_file = file and self:_resolve_file(rel, file) or rel
      target_sig = require('fey.links.signature').key(l.values[1])
    else
      target_file = self:_resolve_file(rel, l.target)
      target_sig = l.attrs.section or l.attrs.heading
    end
    db:run(
      [[INSERT INTO links(file_id, heading_ord, kind, target, target_file, target_sig, description, line, meta)
        VALUES(:file_id, :heading_ord, :kind, :target, :target_file, :target_sig, :description, :line, :meta)]],
      {
        file_id = file_id,
        heading_ord = l.heading_ord,
        kind = l.kind,
        target = l.target,
        target_file = target_file,
        target_sig = target_sig,
        description = l.description,
        line = l.line,
        meta = encode({ values = l.values, attrs = as_map(l.attrs) }),
      }
    )
  end

  for _, l in ipairs(meta.labels) do
    db:run(
      'INSERT INTO labels(file_id, heading_ord, label) VALUES(:file_id, :heading_ord, :label)',
      { file_id = file_id, heading_ord = l.heading_ord, label = l.label }
    )
  end

  local names = vim.tbl_keys(meta.properties)
  table.sort(names)
  for _, name in ipairs(names) do
    db:run(
      'INSERT INTO properties(file_id, name, value) VALUES(:file_id, :name, :value)',
      { file_id = file_id, name = name, value = encode(meta.properties[name]) }
    )
  end
end

---Read, parse and store one file. Never throws: failures are recorded on the file row
---so an unparsable file is not retried until it changes.
---@param rel string
---@param entry { mtime: integer, size: integer }
---@return boolean ok
function Vault:_index_entry(rel, entry)
  local fh = io.open(vim.fs.joinpath(self.root, rel), 'rb')
  local src = fh and fh:read('*a')
  if fh then fh:close() end
  if not src then
    self:_store(rel, entry, nil, { 'could not read file' })
    return false
  end

  local ok, meta = pcall(extract.extract, src, {
    label_tags = self.opts.label_tags,
    link_tags = self.opts.link_tags,
  })
  if not ok then
    self:_store(rel, entry, nil, { 'extraction failed: ' .. tostring(meta) })
    return false
  end
  self:_store(rel, entry, meta, meta.errors)
  return true
end

---@return boolean ok
---@return string|nil err
local function parser_available()
  local ok, err = pcall(vim.treesitter.language.add, 'fey')
  return ok, not ok and tostring(err) or nil
end

---Bring the index up to date: new and changed files are parsed, deleted ones dropped.
---Files are compared by mtime and size. Parsing happens in short slices between
---event loop iterations so the editor stays responsive; a newer scan cancels this one.
---@param opts? { full?: boolean }  `full` throws the index away first
---@param on_done? fun(stats: FeyVaultScanStats|nil, err: string|nil)
function Vault:scan(opts, on_done)
  opts = opts or {}
  local function fail(err)
    self.state, self.last_error = 'error', err
    if on_done then on_done(nil, err) end
  end

  local ok, err = self:open()
  if not ok then return fail(err) end
  local parser_ok, parser_err = parser_available()
  if not parser_ok then return fail('fey tree-sitter parser unavailable: ' .. parser_err) end

  self.gen = self.gen + 1
  local gen = self.gen
  self.state = 'indexing'

  local db = assert(self.db)
  if opts.full then
    db:run('DELETE FROM files')
    self.revision = (self.revision or 0) + 1
  end

  local found = fs.scan_fey_files(self.root, { ignore = self.opts.ignore })
  local existing = {}
  for _, row in ipairs(db:run('SELECT path, mtime, size FROM files')) do
    existing[row.path] = row
  end

  local queue, removed = {}, {}
  local total = 0
  for rel, entry in pairs(found) do
    total = total + 1
    local old = existing[rel]
    if not old or old.mtime ~= entry.mtime or old.size ~= entry.size then table.insert(queue, entry) end
  end
  for rel in pairs(existing) do
    if not found[rel] then table.insert(removed, rel) end
  end
  table.sort(queue, function(a, b) return a.path < b.path end)

  local stats = { total = total, indexed = 0, removed = #removed, failed = 0 }
  local budget = (self.opts.time_budget_ms or 10) * 1e6

  local function finish()
    self.state, self.last_error, self.stats = 'ready', nil, stats
    vim.api.nvim_exec_autocmds('User', {
      pattern = 'FeyVaultIndexed',
      modeline = false,
      data = { root = self.root, stats = stats },
    })
    if on_done then on_done(stats) end
  end

  local ok_rm, rm_err = pcall(db.transaction, db, function()
    for _, rel in ipairs(removed) do
      db:run('DELETE FROM files WHERE path = :path', { path = rel })
    end
    self.revision = (self.revision or 0) + 1
  end)
  if not ok_rm then return fail(tostring(rm_err)) end

  local i = 0
  local function step()
    if gen ~= self.gen or not self.db then return end -- superseded or closed
    local t0 = uv.hrtime()
    local ok_step, step_err = pcall(db.transaction, db, function()
      repeat
        i = i + 1
        local entry = queue[i]
        if self:_index_entry(entry.path, entry) then stats.indexed = stats.indexed + 1 else stats.failed = stats.failed + 1 end
      until i >= #queue or uv.hrtime() - t0 > budget
    end)
    if not ok_step then return fail(tostring(step_err)) end
    if i < #queue then vim.defer_fn(step, 1) else finish() end
  end

  if #queue == 0 then finish() else vim.schedule(step) end
end

---Synchronously (re)index a single file, e.g. after it was saved
---@param path string absolute path
---@return boolean indexed false when the file is outside the vault or ignored
function Vault:index_path(path)
  local rel = vim.fs.relpath(self.root, path)
  if not rel or rel:match('^%.%./') then return false end
  local parts = vim.split(rel, '/', { plain = true })
  for i, part in ipairs(parts) do
    if i < #parts and part:sub(1, 1) == '.' then return false end -- hidden directory
    if vim.tbl_contains(self.opts.ignore, part) then return false end
  end
  if not require('fey.utils').is_fey_file(rel) then return false end
  local ok = self:open() and parser_available()
  if not ok then return false end

  local stat = uv.fs_stat(path)
  local db = assert(self.db)
  if not stat then
    db:run('DELETE FROM files WHERE path = :path', { path = rel })
    self.revision = (self.revision or 0) + 1
    return true
  end
  db:transaction(function()
    self:_index_entry(rel, {
      mtime = stat.mtime.sec * 1000 + math.floor(stat.mtime.nsec / 1e6),
      size = stat.size,
    })
  end)
  vim.api.nvim_exec_autocmds('User', {
    pattern = 'FeyVaultFileIndexed',
    modeline = false,
    data = { root = self.root, path = rel },
  })
  return true
end

-- Queries -------------------------------------------------------------------

---Run a read-only query against the index
---@param sql string
---@param params? table
---@return table[]
function Vault:query(sql, params)
  assert(self:open())
  return (assert(self.db)):run(sql, params)
end

---@return table[] files path, title, mtime, size
function Vault:files() return self:query('SELECT path, title, mtime, size FROM files ORDER BY path') end

---A file with its decoded document data
---@param path string relative to the vault root
---@return table|nil
function Vault:get_file(path)
  local row = self:query('SELECT * FROM files WHERE path = :path', { path = path })[1]
  if not row then return nil end
  row.data, row.errors = decode(row.data), decode(row.errors)
  return row
end

---@param path string
---@return table[] headings in document order, `data` decoded
function Vault:headings(path)
  local rows = self:query(
    [[SELECT h.* FROM headings h JOIN files f ON f.id = h.file_id
      WHERE f.path = :path ORDER BY h.ord]],
    { path = path }
  )
  for _, row in ipairs(rows) do
    row.data = decode(row.data)
  end
  return rows
end

---Every occurrence of a syntactic tag with the given name
---@param name string
---@return table[] rows with `path`, `line`, `vals` and `attrs` decoded
function Vault:tags(name)
  local rows = self:query(
    [[SELECT f.path, t.* FROM tags t JOIN files f ON f.id = t.file_id
      WHERE t.name = :name ORDER BY f.path, t.line]],
    { name = name }
  )
  for _, row in ipairs(rows) do
    row.vals, row.attrs = decode(row.vals) or {}, decode(row.attrs) or {}
  end
  return rows
end

---All labels with the number of files using them
---@return { label: string, count: integer }[]
function Vault:labels()
  return self:query(
    [[SELECT label, COUNT(DISTINCT file_id) AS count FROM labels
      GROUP BY label ORDER BY label]]
  )
end

---@param label string case insensitive
---@return table[] files path, title
function Vault:files_with_label(label)
  return self:query(
    [[SELECT DISTINCT f.path, f.title FROM files f JOIN labels l ON l.file_id = f.id
      WHERE l.label = :label ORDER BY f.path]],
    { label = label }
  )
end

---Files whose document data has `name` set (and, when given, to `value`)
---@param name string
---@param value? any compared with the stored JSON value
---@return table[] files path, title, value (decoded)
function Vault:files_with_property(name, value)
  local rows = self:query(
    [[SELECT f.path, f.title, p.value FROM properties p JOIN files f ON f.id = p.file_id
      WHERE p.name = :name ORDER BY f.path]],
    { name = name }
  )
  local out = {}
  for _, row in ipairs(rows) do
    row.value = decode(row.value)
    if value == nil or vim.deep_equal(row.value, value) then table.insert(out, row) end
  end
  return out
end

---Links and section tags that point to a file, or to one of its sections when
---`signature` is given. Because the destination is stored as text, this stays
---correct after headings were reindexed once the referencing files are re-saved.
---@param path string
---@param signature? string heading signature, e.g. 'I.A.'
---@return table[] rows: source `path`, `line`, `kind`, `target`, `target_sig`, `description`
function Vault:backlinks(path, signature)
  local sql = [[SELECT f.path, l.line, l.kind, l.target, l.target_file, l.target_sig, l.description, l.heading_ord
    FROM links l JOIN files f ON f.id = l.file_id WHERE l.target_file = :path]]
  local params = { path = path }
  if signature then
    sql = sql .. ' AND l.target_sig = :sig'
    params.sig = require('fey.links.signature').key(signature)
  end
  return self:query(sql .. ' ORDER BY f.path, l.line', params)
end

---Links and section tags written in a file
---@param path string
---@return table[]
function Vault:links(path)
  return self:query(
    [[SELECT l.* FROM links l JOIN files f ON f.id = l.file_id
      WHERE f.path = :path ORDER BY l.line]],
    { path = path }
  )
end

return Vault
