-- A vault is a directory containing a `.fey/` folder. The folder holds a SQLite
-- database (`vault.db`) with the metadata of every Fey file below the vault root,
-- so other code can search and query the notes without parsing them again.
--
-- Tables (all `path` columns are relative to the vault root):
--
--   files       id, path, mtime (ms), size, title, data (JSON), errors (JSON), indexed_at
--   headings    file_id, ord, parent_ord, level, signature, title, path, line, end_line, data (JSON), props (JSON map)
--   tags        file_id, heading_ord, kind, name, line, region, vals (JSON list), attrs (JSON map)
--   links       file_id, heading_ord, kind, target, target_ref, target_file, target_sig, description, line, meta (JSON)
--   labels      file_id, heading_ord, label, container, line
--   properties  file_id, name, value (JSON): top level keys of the document data
--   dates       file_id, heading_ord, line, col, kind (date, scheduled, deadline, closed, clock), active, start_ts, start_time, end_ts, end_time, repeater, warn
--   tasks       file_id, heading_ord, line, kind (heading, item), state, done, priority, title
--
-- `heading_ord` is NULL for document level entries. `links.target_file` and
-- `links.target_sig` hold the resolved destination, so the backlinks of a file or
-- section are a single indexed lookup (see `Vault:backlinks`).
local Db = require('fey.vault.db')
local extract = require('fey.vault.extract')
local fs = require('fey.utils.fs')
local uv = vim.uv

local SCHEMA_VERSION = 6

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
  data TEXT,
  props TEXT                 -- JSON map: the keys of the prop tags of the heading
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
  region TEXT,               -- title|body|text|document, see fey.files.elements.tags.region
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
  target_ref TEXT,           -- the hollow of a link that names one: `court:notes`, `current` (see fey.hollow.tree)
  target_file TEXT,          -- relative to the hollow of the link, or to the hollow named by target_ref
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
  label TEXT NOT NULL COLLATE NOCASE,
  container TEXT,            -- title|body|text|document|data: what holds the label
  line INTEGER
);
CREATE INDEX labels_label ON labels(label);
CREATE INDEX labels_file ON labels(file_id);
CREATE TABLE properties (
  file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  value TEXT
);
CREATE INDEX properties_name ON properties(name, file_id);
CREATE TABLE dates (
  id INTEGER PRIMARY KEY,
  file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
  heading_ord INTEGER,
  line INTEGER,
  col INTEGER,
  kind TEXT NOT NULL,        -- date|scheduled|deadline|closed|clock (a clock has no end while it runs)
  active INTEGER NOT NULL,
  start_ts INTEGER,          -- epoch seconds, local time
  start_time INTEGER,        -- 1 when the date has a time of day
  end_ts INTEGER,
  end_time INTEGER,
  repeater TEXT,
  warn TEXT
);
CREATE INDEX dates_file ON dates(file_id);
CREATE INDEX dates_start ON dates(start_ts);
CREATE INDEX dates_kind ON dates(kind, start_ts);
CREATE TABLE tasks (
  id INTEGER PRIMARY KEY,
  file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
  heading_ord INTEGER,
  line INTEGER,
  kind TEXT NOT NULL,        -- heading (a status tag) or item (a checkbox of a list item)
  state TEXT,                -- the todo keyword, or the mark of a checkbox: space, x or -
  done INTEGER NOT NULL,
  priority TEXT,
  title TEXT
);
CREATE INDEX tasks_file ON tasks(file_id);
CREATE INDEX tasks_state ON tasks(state);
]]

local TABLES = { 'tasks', 'dates', 'properties', 'labels', 'links', 'tags', 'headings', 'files' }

---@class FeyVaultOpts
---@field dirname string name of the vault directory. Default '.fey'
---@field db_name string database file inside `dirname`. Default 'vault.db'
---@field ignore string[] names of directories/files never indexed
---@field label_tags string[] tag names whose values are labels
---@field link_tags string[] tag names that point to another file or section
---@field meta_tags string[] names of heading metadata tags, left out of heading titles
---@field live_index boolean index edited buffers while they are typed in, not only when saved
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
      [[INSERT INTO headings(file_id, ord, parent_ord, level, signature, title, path, line, end_line, data, props)
        VALUES(:file_id, :ord, :parent_ord, :level, :signature, :title, :path, :line, :end_line, :data, :props)]],
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
        props = encode_map(h.props or {}),
      }
    )
  end

  for _, t in ipairs(meta.tags) do
    db:run(
      [[INSERT INTO tags(file_id, heading_ord, kind, name, line, region, vals, attrs)
        VALUES(:file_id, :heading_ord, :kind, :name, :line, :region, :vals, :attrs)]],
      {
        file_id = file_id,
        heading_ord = t.heading_ord,
        kind = t.kind,
        name = t.name,
        line = t.line,
        region = t.region,
        vals = encode(t.values),
        attrs = encode_map(t.attrs),
      }
    )
  end

  for _, l in ipairs(meta.links) do
    local target_file, target_sig, target_ref
    local tree = require('fey.hollow.tree')
    -- the file of a link may name its hollow: `court:notes:history/a.fey`
    local named = l.kind == 'section' and (l.values[2] or l.attrs.file) or l.target
    local ref = named and tree.parse_ref(named)
    if ref then
      target_ref = table.concat(vim.list_extend({ ref.keyword }, ref.names), ':')
      target_file = ref.path
      if l.kind == 'section' then
        target_sig = require('fey.links.signature').key(l.values[1])
      else
        target_sig = l.attrs.section or l.attrs.heading
      end
    elseif l.kind == 'section' then
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
      [[INSERT INTO links(file_id, heading_ord, kind, target, target_ref, target_file, target_sig, description, line, meta)
        VALUES(:file_id, :heading_ord, :kind, :target, :target_ref, :target_file, :target_sig, :description, :line, :meta)]],
      {
        file_id = file_id,
        heading_ord = l.heading_ord,
        kind = l.kind,
        target = l.target,
        target_ref = target_ref,
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
      [[INSERT INTO labels(file_id, heading_ord, label, container, line)
        VALUES(:file_id, :heading_ord, :label, :container, :line)]],
      { file_id = file_id, heading_ord = l.heading_ord, label = l.label, container = l.container, line = l.line }
    )
  end

  for _, d in ipairs(meta.dates) do
    db:run(
      [[INSERT INTO dates(file_id, heading_ord, line, col, kind, active, start_ts, start_time, end_ts, end_time, repeater, warn)
        VALUES(:file_id, :heading_ord, :line, :col, :kind, :active, :start_ts, :start_time, :end_ts, :end_time, :repeater, :warn)]],
      {
        file_id = file_id,
        heading_ord = d.heading_ord,
        line = d.line,
        col = d.col,
        kind = d.kind,
        active = d.active and 1 or 0,
        start_ts = d.start_ts,
        start_time = d.start_time and 1 or 0,
        end_ts = d.end_ts,
        end_time = d.end_time and 1 or 0,
        repeater = d.repeater,
        warn = d.warn,
      }
    )
  end

  for _, t in ipairs(meta.tasks) do
    db:run(
      [[INSERT INTO tasks(file_id, heading_ord, line, kind, state, done, priority, title)
        VALUES(:file_id, :heading_ord, :line, :kind, :state, :done, :priority, :title)]],
      {
        file_id = file_id,
        heading_ord = t.heading_ord,
        line = t.line,
        kind = t.kind,
        state = t.state,
        done = t.done and 1 or 0,
        priority = t.priority,
        title = t.title,
      }
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

---What the indexer needs to know that is not in the file: the names of the tags and the todo keywords
---@param self FeyVault
---@return FeyVaultExtractOpts
local function extract_opts(self)
  local config = require('fey.config')
  return {
    label_tags = self.opts.label_tags,
    link_tags = self.opts.link_tags,
    meta_tags = self.opts.meta_tags,
    date_tags = {
      [config.fey_date_tag_name] = 'date',
      [config.fey_scheduled_tag_name] = 'scheduled',
      [config.fey_deadline_tag_name] = 'deadline',
      [config.fey_closed_tag_name] = 'closed',
    },
    status_tag = config.fey_status_tag_name,
    prop_tag = config.fey_property_tag_name,
    clock_tag = config.fey_clock_tag_name,
    -- the keywords of the file (the `todo` key of its data) or the configured ones
    todo_lookup = function(data_todo)
      local sequences
      if type(data_todo) == 'string' then
        sequences = { vim.split(vim.trim(data_todo), '%s+') }
      elseif type(data_todo) == 'table' and vim.islist(data_todo) then
        sequences = {}
        for _, line in ipairs(data_todo) do
          sequences[#sequences + 1] = vim.split(vim.trim(tostring(line)), '%s+')
        end
      end
      local keywords = sequences and config:build_todo_keywords(sequences) or config:get_todo_keywords()
      return keywords:keys()
    end,
  }
end

---Parse and store one file from its text. Never throws: failures are recorded on the file row
---so an unparsable file is not retried until it changes.
---@param rel string
---@param entry { mtime: integer, size: integer }
---@param src string|nil the text; nil when it could not be read
---@return boolean ok
function Vault:_index_source(rel, entry, src)
  if not src then
    self:_store(rel, entry, nil, { 'could not read file' })
    return false
  end

  local ok, meta = pcall(extract.extract, src, extract_opts(self))
  if not ok then
    self:_store(rel, entry, nil, { 'extraction failed: ' .. tostring(meta) })
    return false
  end
  self:_store(rel, entry, meta, meta.errors)
  return true
end

---Read, parse and store one file from the disk
---@param rel string
---@param entry { mtime: integer, size: integer }
---@return boolean ok
function Vault:_index_entry(rel, entry)
  local fh = io.open(vim.fs.joinpath(self.root, rel), 'rb')
  local src = fh and fh:read('*a')
  if fh then fh:close() end
  return self:_index_source(rel, entry, src)
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

  local found = fs.scan_fey_files(self.root, { ignore = self.opts.ignore, vault_dirname = self.opts.dirname })
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

---The path of a file relative to the vault root, nil when the vault does not index it (outside the vault,
---in a hidden or ignored directory, in another vault inside this one, not a Fey file)
---@param path string absolute path
---@return string|nil rel
function Vault:rel_of(path)
  local rel = vim.fs.relpath(self.root, path)
  if not rel or rel:match('^%.%./') then return nil end
  local parts = vim.split(rel, '/', { plain = true })
  local dir = self.root
  for i, part in ipairs(parts) do
    if i < #parts and part:sub(1, 1) == '.' then return nil end -- hidden directory
    if vim.tbl_contains(self.opts.ignore, part) then return nil end
    if i < #parts then
      dir = vim.fs.joinpath(dir, part)
      if vim.fn.isdirectory(vim.fs.joinpath(dir, self.opts.dirname)) == 1 then return nil end -- another vault
    end
  end
  if not require('fey.utils').is_fey_file(rel) then return nil end
  return rel
end

---Absolute path of a file of the vault
---@param rel string
---@return string
function Vault:abs(rel) return vim.fs.joinpath(self.root, rel) end

---@param rel string
local function fire_indexed(self, rel, live)
  vim.api.nvim_exec_autocmds('User', {
    pattern = 'FeyVaultFileIndexed',
    modeline = false,
    data = { root = self.root, path = rel, live = live or false },
  })
end

---Synchronously (re)index a single file, e.g. after it was saved
---@param path string absolute path
---@return boolean indexed false when the file is outside the vault or ignored
function Vault:index_path(path)
  local rel = self:rel_of(path)
  if not rel then return false end
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
  fire_indexed(self, rel)
  return true
end

---Index the text of a buffer that has not been saved. The file keeps the modification time and size it
---has on the disk, so a scan does not undo this; saving, or `index_path` after the buffer is gone,
---replaces it with what is on the disk.
---@param path string absolute path of the file
---@param lines string[] the text
---@return boolean indexed false when the file is not indexed by this vault or is not on the disk yet
function Vault:index_text(path, lines)
  local rel = self:rel_of(path)
  if not rel then return false end
  local ok = self:open() and parser_available()
  if not ok then return false end
  local stat = uv.fs_stat(path)
  if not stat then return false end

  local db = assert(self.db)
  local src = table.concat(lines, '\n') .. '\n'
  db:transaction(function()
    self:_index_source(rel, {
      mtime = stat.mtime.sec * 1000 + math.floor(stat.mtime.nsec / 1e6),
      size = stat.size,
    }, src)
  end)
  fire_indexed(self, rel, true)
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
---@param opts? { level?: 'file'|'heading', container?: string } only labels of the files themselves or only those given inside headings, and/or only those held by one kind of container (`title`, `body`, `text`, `document`, `data`)
---@return { label: string, count: integer }[]
function Vault:labels(opts)
  opts = opts or {}
  local where, params = {}, {}
  if opts.level == 'file' then where[#where + 1] = 'heading_ord IS NULL' end
  if opts.level == 'heading' then where[#where + 1] = 'heading_ord IS NOT NULL' end
  if opts.container then
    where[#where + 1] = 'container = :container'
    params.container = opts.container
  end
  return self:query(
    'SELECT label, COUNT(DISTINCT file_id) AS count FROM labels'
      .. (#where > 0 and (' WHERE ' .. table.concat(where, ' AND ')) or '')
      .. ' GROUP BY label ORDER BY label',
    params
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

---Labels of a heading as the agenda sees them: its own, those of the headings above it and those of the
---document (`{# labels #}` outside of any heading)
---@return fun(file_id: integer, ord: integer): string[]
function Vault:_label_index()
  local own, parent = {}, {}
  for _, l in ipairs(self:query('SELECT file_id, heading_ord, label FROM labels')) do
    local key = l.file_id .. ':' .. (l.heading_ord or 'file')
    own[key] = own[key] or {}
    table.insert(own[key], l.label)
  end
  for _, h in ipairs(self:query('SELECT file_id, ord, parent_ord FROM headings')) do
    parent[h.file_id .. ':' .. h.ord] = h.parent_ord
  end
  return function(file_id, ord)
    local out, seen = {}, {}
    local function add(key)
      for _, label in ipairs(own[key] or {}) do
        if not seen[label:lower()] then
          seen[label:lower()] = true
          out[#out + 1] = label
        end
      end
    end
    local at, guard = ord, 0
    while at and guard < 64 do
      add(file_id .. ':' .. at)
      at = parent[file_id .. ':' .. at]
      guard = guard + 1
    end
    add(file_id .. ':file')
    return out
  end
end

---Headings for the agenda views that list headings (todo, match, search): each with the labels it has
---(own, inherited and of the document), its props, todo state and priority, and its planning dates
---@param opts? { todo_only?: boolean, path?: string } `todo_only` keeps the headings with an open todo state
---@return table[] rows path, ord, line, end_line, level, signature, title, props, state, done, priority, labels, category, plan (kind to date row: deadline, scheduled, closed)
function Vault:agenda_headings(opts)
  opts = opts or {}
  local where, params = {}, {}
  if opts.path then
    where[#where + 1] = 'f.path = :path'
    params.path = opts.path
  end
  local rows = self:query(
    [[SELECT f.path, h.file_id, h.ord, h.line, h.end_line, h.level, h.signature, h.title, h.props,
        t.state, t.done, t.priority,
        (SELECT p.value FROM properties p WHERE p.file_id = h.file_id AND p.name = 'category') AS category
      FROM headings h JOIN files f ON f.id = h.file_id
      LEFT JOIN tasks t ON t.file_id = h.file_id AND t.heading_ord = h.ord AND t.kind = 'heading'
      ]] .. (#where > 0 and ('WHERE ' .. table.concat(where, ' AND ')) or '') .. [[

      ORDER BY f.path, h.ord]],
    params
  )
  local labels_of = self:_label_index()
  local plan = {}
  for _, d in ipairs(self:query(
    [[SELECT file_id, heading_ord, kind, active, start_ts, start_time, end_ts, end_time, repeater, warn, line, col
      FROM dates WHERE kind IN ('deadline', 'scheduled', 'closed') AND heading_ord IS NOT NULL ORDER BY start_ts]]
  )) do
    local key = d.file_id .. ':' .. d.heading_ord
    plan[key] = plan[key] or {}
    plan[key][d.kind] = plan[key][d.kind] or d
  end
  local out = {}
  for _, row in ipairs(rows) do
    row.props = decode(row.props) or {}
    row.category = decode(row.category)
    row.labels = labels_of(row.file_id, row.ord)
    row.plan = plan[row.file_id .. ':' .. row.ord] or {}
    row.done = row.done == 1
    row.heading_ord = row.ord
    row.heading_title = row.title
    row.heading_line = row.line
    out[#out + 1] = row
  end
  return out
end

---Dates of the vault with the heading and the task they belong to, ordered by start
---@param opts? { from?: integer, to?: integer, kinds?: string[], active?: boolean, open_only?: boolean, path?: string } `from`/`to` are epoch seconds: a date counts when it starts before `to` and ends after `from` (a repeating date counts when it started before `to`); `open_only` leaves out the dates of headings whose task is done; `path` limits to one file
---@return table[] rows path, line, col, heading_ord, heading_title, signature, kind, active, start_ts, start_time, end_ts, end_time, repeater, warn, state, done, priority, heading_line, props (map of the prop tags of the heading), category (the `category` of the document), labels (of the heading)
function Vault:dates(opts)
  opts = opts or {}
  local where, params = {}, {}
  if opts.kinds and #opts.kinds > 0 then
    local marks = {}
    for i, kind in ipairs(opts.kinds) do
      params['kind' .. i] = kind
      marks[i] = ':kind' .. i
    end
    where[#where + 1] = 'd.kind IN (' .. table.concat(marks, ', ') .. ')'
  end
  if opts.active ~= nil then
    where[#where + 1] = 'd.active = :active'
    params.active = opts.active and 1 or 0
  end
  if opts.from or opts.to then
    local parts = {}
    local to, from = opts.to, opts.from
    local overlap = {}
    if to then
      overlap[#overlap + 1] = 'd.start_ts <= :to'
      params.to = to
    end
    if from then
      overlap[#overlap + 1] = 'COALESCE(d.end_ts, d.start_ts) >= :from'
      params.from = from
    end
    parts[1] = '(' .. table.concat(overlap, ' AND ') .. ')'
    if to then parts[2] = '(d.repeater IS NOT NULL AND d.start_ts <= :to)' end
    where[#where + 1] = '(' .. table.concat(parts, ' OR ') .. ')'
  end
  if opts.open_only then where[#where + 1] = '(t.done IS NULL OR t.done = 0)' end
  if opts.path then
    where[#where + 1] = 'f.path = :path'
    params.path = opts.path
  end

  local rows = self:query(
    [[SELECT f.path, d.line, d.col, d.heading_ord, h.title AS heading_title, h.signature, d.kind, d.active,
        d.start_ts, d.start_time, d.end_ts, d.end_time, d.repeater, d.warn, t.state, t.done, t.priority,
        h.line AS heading_line, h.end_line, h.props, h.parent_ord, d.file_id,
        (SELECT p.value FROM properties p WHERE p.file_id = d.file_id AND p.name = 'category') AS category
      FROM dates d JOIN files f ON f.id = d.file_id
      LEFT JOIN headings h ON h.file_id = d.file_id AND h.ord = d.heading_ord
      LEFT JOIN tasks t ON t.file_id = d.file_id AND t.heading_ord = d.heading_ord AND t.kind = 'heading'
      ]] .. (#where > 0 and ('WHERE ' .. table.concat(where, ' AND ')) or '') .. [[

      ORDER BY d.start_ts, f.path, d.line]],
    params
  )
  if #rows == 0 then return rows end
  local labels_of = self:_label_index()
  for _, row in ipairs(rows) do
    row.labels = row.heading_ord and labels_of(row.file_id, row.heading_ord) or {}
    row.props = decode(row.props) or {}
    row.category = decode(row.category)
    row.file_id = nil
  end
  return rows
end

---Tasks of the vault (headings with a todo keyword or a priority) with their labels
---@param opts? { state?: string|string[], done?: boolean, priority?: string, label?: string, path?: string, kind?: 'heading'|'item'|'all' } `kind`: the headings with a status (default), the checkbox items, or both
---@return table[] rows path, line, heading_ord, title, signature, state, done, priority, kind, labels (list)
function Vault:tasks(opts)
  opts = opts or {}
  local where, params = {}, {}
  if opts.kind ~= 'all' then
    where[#where + 1] = 't.kind = :kind'
    params.kind = opts.kind or 'heading'
  end
  if opts.state then
    local states = type(opts.state) == 'table' and opts.state or { opts.state }
    local marks = {}
    for i, state in ipairs(states) do
      params['state' .. i] = state
      marks[i] = ':state' .. i
    end
    where[#where + 1] = 't.state IN (' .. table.concat(marks, ', ') .. ')'
  end
  if opts.done ~= nil then
    where[#where + 1] = 't.done = :done'
    params.done = opts.done and 1 or 0
  end
  if opts.priority then
    where[#where + 1] = 't.priority = :priority'
    params.priority = opts.priority
  end
  if opts.label then
    where[#where + 1] = [[EXISTS (SELECT 1 FROM labels l WHERE l.file_id = t.file_id AND l.heading_ord = t.heading_ord
      AND (l.label = :label OR l.label LIKE :label_p ESCAPE '\'))]]
    params.label = opts.label
    params.label_p = opts.label:gsub('[%%_\\]', '\\%0') .. '/%'
  end
  if opts.path then
    where[#where + 1] = 'f.path = :path'
    params.path = opts.path
  end

  local rows = self:query(
    [[SELECT f.path, t.line, t.heading_ord, t.title, h.signature, t.state, t.done, t.priority, t.kind, t.file_id
      FROM tasks t JOIN files f ON f.id = t.file_id
      LEFT JOIN headings h ON h.file_id = t.file_id AND h.ord = t.heading_ord
      ]] .. (#where > 0 and ('WHERE ' .. table.concat(where, ' AND ')) or '') .. [[

      ORDER BY f.path, t.line]],
    params
  )
  -- labels of the headings, one query for all
  local labels = {}
  for _, l in ipairs(self:query('SELECT file_id, heading_ord, label FROM labels WHERE heading_ord IS NOT NULL')) do
    local key = l.file_id .. ':' .. l.heading_ord
    labels[key] = labels[key] or {}
    table.insert(labels[key], l.label)
  end
  for _, row in ipairs(rows) do
    row.labels = row.heading_ord and labels[row.file_id .. ':' .. row.heading_ord] or {}
    row.file_id = nil
    row.done = row.done == 1
  end
  return rows
end

---Footnotes of the notes: one row per label of a file, with the number of references, the line of the first one
---and whether a definition (the pair tag) exists. A reference without a definition is a missing footnote
---@param opts? { path?: string, missing?: boolean, unused?: boolean } `missing`: referenced and not defined, `unused`: defined and not referenced
---@return table[] rows path, label, references, line (first reference), defined, definition_line
function Vault:footnotes(opts)
  opts = opts or {}
  local name = require('fey.config').fey_footnote_tag_name
  local sql = [[SELECT f.path, t.line, t.kind, t.vals FROM tags t JOIN files f ON f.id = t.file_id
    WHERE t.name = :name]]
  local params = { name = name }
  if opts.path then
    sql = sql .. ' AND f.path = :path'
    params.path = opts.path
  end
  local by_key, order = {}, {}
  for _, row in ipairs(self:query(sql .. ' ORDER BY f.path, t.line', params)) do
    local vals = decode(row.vals)
    local label = vals and vals[1] and tostring(vals[1]) or nil
    if label and label ~= '' then
      local key = row.path .. '\0' .. label
      local entry = by_key[key]
      if not entry then
        entry = { path = row.path, label = label, references = 0, defined = false }
        by_key[key] = entry
        order[#order + 1] = entry
      end
      if row.kind == 'pair' or row.kind == 'line' or row.kind == 'block' then
        if not entry.defined then
          entry.defined = true
          entry.definition_line = row.line
        end
      else
        entry.references = entry.references + 1
        entry.line = entry.line or row.line
      end
    end
  end
  local out = {}
  for _, entry in ipairs(order) do
    local keep = true
    if opts.missing then keep = entry.references > 0 and not entry.defined end
    if opts.unused then keep = entry.defined and entry.references == 0 end
    if keep then out[#out + 1] = entry end
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
    FROM links l JOIN files f ON f.id = l.file_id WHERE l.target_file = :path AND l.target_ref IS NULL]]
  local params = { path = path }
  if signature then
    sql = sql .. ' AND l.target_sig = :sig'
    params.sig = require('fey.links.signature').key(signature)
  end
  return self:query(sql .. ' ORDER BY f.path, l.line', params)
end

---Links and section tags written in this vault that name another vault and point to a file of it, or to
---one of its sections when `signature` is given: `{@ link, court:notes/a.fey @}`
---@param target_root string root of the vault the files is in
---@param path string
---@param signature? string
---@return table[] rows like `backlinks`, with `target_ref`
function Vault:foreign_backlinks(target_root, path, signature)
  local sql = [[SELECT f.path, l.line, l.kind, l.target, l.target_ref, l.target_file, l.target_sig, l.description,
      l.heading_ord
    FROM links l JOIN files f ON f.id = l.file_id WHERE l.target_ref IS NOT NULL AND l.target_file = :path]]
  local params = { path = path }
  if signature then
    sql = sql .. ' AND l.target_sig = :sig'
    params.sig = require('fey.links.signature').key(signature)
  end
  local tree = require('fey.hollow.tree')
  local want = tree.realpath(target_root)
  local out = {}
  for _, row in ipairs(self:query(sql .. ' ORDER BY f.path, l.line', params)) do
    local root = tree.resolve_ref(row.target_ref, self.root)
    if root and tree.realpath(root) == want then out[#out + 1] = row end
  end
  return out
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
