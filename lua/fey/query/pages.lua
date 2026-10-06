-- Page and section objects backed by the vault index.
--
-- Following Datacore's design the objects are lazy and cached per index
-- revision: a query only pays for the fields it touches, relations
-- (labels, links, headings) are loaded for the whole vault with one SQL query
-- the first time any page needs them, and nothing is rebuilt until the index
-- changes.
local V = require('fey.query.values')
local ops = require('fey.query.ops')

local NULL = V.NULL
local M = {}

-- Lazy objects share one metatable; `__resolve(obj, key)` supplies missing fields.
V.PAGE.__index = function(t, k)
  if type(k) == 'string' and k:sub(1, 2) == '__' then return nil end
  local resolve = rawget(t, '__resolve')
  if resolve then return resolve(t, k) end
  return nil
end

---@param resolve fun(t: table, k: string): any
---@param keys fun(): string[]
---@param raw? table
local function lazy(resolve, keys, raw)
  raw = raw or {}
  raw.__resolve = resolve
  raw.__keys = keys
  return setmetatable(raw, V.PAGE)
end

M.lazy = lazy

---Decode a JSON column into query values
---@param s string|nil
local function decode(s)
  if s == nil then return nil end
  local ok, v = pcall(vim.json.decode, s)
  if not ok then return nil end
  return V.from_json(v, true)
end

---An object with extra fields in front of a parent (rows made by GROUP BY and FLATTEN)
---@param parent any
---@param fields table<string, any>
---@param order? string[]
function M.derive(parent, fields, order)
  local names = order or vim.tbl_keys(fields)
  return lazy(function(t, k)
    local v = rawget(t, '__fields')[k]
    if v ~= nil then return v end
    if parent ~= nil then
      local pv = ops.get(parent, k)
      if pv ~= NULL then return pv end
    end
    return nil
  end, function()
    local keys, seen = {}, {}
    for _, k in ipairs(names) do
      if not seen[k] then keys[#keys + 1], seen[k] = k, true end
    end
    if parent ~= nil and V.is_object(parent) then
      for _, k in ipairs(V.keys(parent)) do
        if not seen[k] then keys[#keys + 1], seen[k] = k, true end
      end
    end
    return keys
  end, { __fields = fields, __parent = parent })
end

---@class FeyQueryStore
---@field vault FeyVault
---@field revision integer
local Store = {}
Store.__index = Store

---@type table<string, FeyQueryStore>
local stores = {}

---The cached store of a vault (rebuilt lazily when the index changed)
---@param vault FeyVault
---@return FeyQueryStore
function M.store(vault)
  local store = stores[vault.root]
  if store and store.vault == vault and store.revision == (vault.revision or 0) then return store end
  store = setmetatable({ vault = vault, revision = vault.revision or 0 }, Store)
  stores[vault.root] = store
  return store
end

-- Relation loaders (each runs one query for the whole vault) -------------------

---Labels by file (all of them, those of the file itself and those of its headings) and by section
---@return table<string, string[]> all
---@return table<string, string[]> by_section keyed by `path .. '\0' .. heading_ord`
---@return table<string, string[]> by_file labels of the file itself (not given inside a heading)
---@return table<string, string[]> by_heading labels given inside the headings of the file
function Store:_labels()
  if self.labels then return self.labels, self.section_labels, self.file_labels, self.heading_labels end
  local by_path, by_section, by_file, by_heading = {}, {}, {}, {}
  local rows = self.vault:query(
    [[SELECT f.path, l.heading_ord, l.label FROM labels l JOIN files f ON f.id = l.file_id ORDER BY f.path, l.label]]
  )
  local function add(map, key, label)
    local list = map[key] or {}
    map[key] = list
    list[#list + 1] = label
  end
  for _, r in ipairs(rows) do
    add(by_path, r.path, r.label)
    if r.heading_ord then
      add(by_section, r.path .. '\0' .. r.heading_ord, r.label)
      add(by_heading, r.path, r.label)
    else
      add(by_file, r.path, r.label)
    end
  end
  self.labels, self.section_labels, self.file_labels, self.heading_labels = by_path, by_section, by_file, by_heading
  return by_path, by_section, by_file, by_heading
end

function Store:_links()
  if self.outlinks then return self.outlinks, self.inlinks end
  local out, inn = {}, {}
  local rows = self.vault:query(
    [[SELECT f.path, l.target, l.target_file, l.target_sig, l.description
      FROM links l JOIN files f ON f.id = l.file_id ORDER BY f.path, l.line]]
  )
  local seen_in = {}
  for _, r in ipairs(rows) do
    local dest = r.target_file or r.target
    local link = V.link(dest, r.description, r.target_sig)
    out[r.path] = out[r.path] or {}
    table.insert(out[r.path], link)
    if r.target_file and r.target_file ~= r.path then
      local key = r.target_file .. '\0' .. r.path
      if not seen_in[key] then
        seen_in[key] = true
        inn[r.target_file] = inn[r.target_file] or {}
        table.insert(inn[r.target_file], V.link(r.path))
      end
    end
  end
  self.outlinks, self.inlinks = out, inn
  return out, inn
end

function Store:_headings()
  if self.headings then return self.headings end
  local by_path = {}
  local rows = self.vault:query(
    [[SELECT f.path AS file_path, h.ord, h.parent_ord, h.level, h.signature, h.title, h.path AS outline,
        h.line, h.end_line, h.data
      FROM headings h JOIN files f ON f.id = h.file_id ORDER BY f.path, h.ord]]
  )
  for _, r in ipairs(rows) do
    by_path[r.file_path] = by_path[r.file_path] or {}
    table.insert(by_path[r.file_path], r)
  end
  self.headings = by_path
  return by_path
end

-- Files ------------------------------------------------------------------------

local DAILY = '^(%d%d%d%d%-%d%d%-%d%d)$'

---@param store FeyQueryStore
---@param page table
---@param row table
local function new_file(store, page, row)
  local path = row.path
  local name = path:match('([^/]+)$')
  local stem = name:gsub('%.[^.]+$', '')
  local ext = name:match('%.([^.]+)$') or ''

  local function resolve(t, k)
    local v
    if k == 'name' then v = stem
    elseif k == 'path' then v = path
    elseif k == 'folder' then v = path:match('^(.*)/[^/]+$') or ''
    elseif k == 'ext' then v = ext
    elseif k == 'link' then v = V.link(path)
    elseif k == 'size' then v = row.size
    elseif k == 'mtime' then v = V.date(row.mtime / 1000, true)
    elseif k == 'mday' then
      local f = os.date('*t', math.floor(row.mtime / 1000)) --[[@as osdateparam]]
      v = V.date(V.make_ts(f.year, f.month, f.day))
    elseif k == 'ctime' or k == 'cday' then
      local stat = vim.uv.fs_stat(vim.fs.joinpath(store.vault.root, path))
      local secs = stat and stat.birthtime and stat.birthtime.sec > 0 and stat.birthtime.sec or row.mtime / 1000
      if k == 'ctime' then
        v = V.date(secs, true)
      else
        local f = os.date('*t', math.floor(secs)) --[[@as osdateparam]]
        v = V.date(V.make_ts(f.year, f.month, f.day))
      end
    elseif k == 'labels' or k == 'heading_labels' or k == 'tags' or k == 'etags' then
      -- `labels` are the labels of the file itself, `heading_labels` those given inside its headings;
      -- `tags` and `etags` (the Dataview names) count every label of the file
      local all, _, own, in_headings = store:_labels()
      local labels = ({ labels = own, heading_labels = in_headings })[k]
      labels = (labels or all)[path] or {}
      local out = {}
      local seen = {}
      for _, l in ipairs(labels) do
        local base = l
        if k == 'labels' or k == 'heading_labels' then
          if not seen[base] then out[#out + 1], seen[base] = base, true end
        elseif k == 'etags' then
          if not seen['#' .. base] then out[#out + 1], seen['#' .. base] = '#' .. base, true end
        else
          -- like Dataview, `a/b` also counts as `a`
          local acc = ''
          for part in base:gmatch('[^/]+') do
            acc = acc == '' and part or (acc .. '/' .. part)
            if not seen['#' .. acc] then out[#out + 1], seen['#' .. acc] = '#' .. acc, true end
          end
        end
      end
      v = V.list(out)
    elseif k == 'outlinks' then
      v = V.list(vim.deepcopy((store:_links())[path] or {}))
    elseif k == 'inlinks' then
      v = V.list(vim.deepcopy(select(2, store:_links())[path] or {}))
    elseif k == 'aliases' then
      local a = ops.get(page, 'aliases')
      v = V.is_list(a) and a or (a ~= NULL and V.list({ a }) or V.list({}))
    elseif k == 'headings' then
      local out = {}
      for _, h in ipairs(store:_headings()[path] or {}) do
        out[#out + 1] = V.object({
          title = h.title, level = h.level, signature = h.signature, line = h.line,
          link = V.link(path, h.title, h.signature),
        })
      end
      v = V.list(out)
    elseif k == 'frontmatter' or k == 'data' then
      v = rawget(page, '__data') or V.object({})
    elseif k == 'day' then
      local d = stem:match(DAILY)
      v = d and V.parse_date(d) or NULL
    elseif k == 'tasks' or k == 'lists' then
      v = V.list({}) -- Fey has no task or list-item index (yet)
    else
      return nil
    end
    rawset(t, k, v)
    return v
  end

  return lazy(resolve, function()
    return {
      'aliases', 'cday', 'ctime', 'day', 'etags', 'ext', 'folder', 'frontmatter', 'heading_labels', 'headings', 'inlinks', 'labels',
      'link', 'mday', 'mtime', 'name', 'outlinks', 'path', 'size', 'tags',
    }
  end)
end

---@param store FeyQueryStore
---@param row table
local function new_page(store, row)
  local page
  local data_loaded = false
  local data
  local function load_data()
    if data_loaded then return data end
    data_loaded = true
    local d = decode(row.data)
    data = V.is_object(d) and d or V.object({})
    rawset(page, '__data', data)
    return data
  end

  page = lazy(function(t, k)
    if k == 'file' then
      local f = new_file(store, t, row)
      rawset(t, 'file', f)
      return f
    end
    if k == 'title' and row.title and rawget(load_data(), 'title') == nil then return row.title end
    local d = load_data()
    local v = d[k]
    if v == nil and type(k) == 'string' then
      local norm = ops.normalize_key(k)
      for _, key in ipairs(V.keys(d)) do
        if ops.normalize_key(key) == norm then return d[key] end
      end
    end
    return v
  end, function()
    local keys = { 'file' }
    for _, k in ipairs(V.keys(load_data())) do
      keys[#keys + 1] = k
    end
    return keys
  end, { __path = row.path })
  return page
end

-- Page set -----------------------------------------------------------------------

---All pages ordered by path
---@return table[]
function Store:pages()
  if self.page_list then return self.page_list end
  local list, by_path = {}, {}
  for _, row in ipairs(self.vault:query('SELECT path, title, mtime, size, data FROM files ORDER BY path')) do
    local page = new_page(self, row)
    list[#list + 1] = page
    by_path[row.path] = page
  end
  self.page_list, self.page_by_path = list, by_path
  return list
end

---@param path string
---@return table|nil
function Store:page(path)
  self:pages()
  return self.page_by_path[path]
end

---Find the file a link text points to: a path, a path without extension, or a unique file name
---@param text string
---@return string|nil path
function Store:resolve(text)
  self:pages()
  if not self.by_stem then
    local by_stem, by_noext = {}, {}
    for path in pairs(self.page_by_path) do
      local noext = path:gsub('%.[^./]+$', '')
      by_noext[noext:lower()] = path
      local stem = noext:match('([^/]+)$'):lower()
      by_stem[stem] = by_stem[stem] or {}
      table.insert(by_stem[stem], path)
    end
    for _, paths in pairs(by_stem) do
      table.sort(paths, function(a, b) return #a < #b or (#a == #b and a < b) end)
    end
    self.by_stem, self.by_noext = by_stem, by_noext
  end
  text = text:gsub('^%./', '')
  if self.page_by_path[text] then return text end
  local noext = text:gsub('%.[^./]+$', ''):lower()
  if self.by_noext[noext] then return self.by_noext[noext] end
  local stems = self.by_stem[noext:match('([^/]+)$') or noext]
  return stems and stems[1] or nil
end

---@param value any a link, string or page
---@return string|nil path
function Store:path_of(value)
  if V.is_link(value) then return self:resolve(value.path) end
  if type(value) == 'string' then return self:resolve(value) end
  if V.is_object(value) then
    local file = ops.get(value, 'file')
    local path = V.is_object(file) and ops.get(file, 'path')
    if type(path) == 'string' then return path end
  end
  return nil
end

-- Sources ----------------------------------------------------------------------------

---@param s string
local function like_escape(s) return (s:gsub('[%%_\\]', '\\%0')) end

---@param rows table[]
---@param column string
---@return table<string, true>
local function to_set(rows, column)
  local set = {}
  for _, r in ipairs(rows) do
    if r[column] then set[r[column]] = true end
  end
  return set
end

---@class FeySourceResult
---@field set? table<string, true> pages that match; nil means every page
---@field kind? 'page'|'section'

---@param a table|nil
---@param b table|nil
local function intersect(a, b)
  if a == nil then return b end
  if b == nil then return a end
  local out = {}
  for k in pairs(a) do
    if b[k] then out[k] = true end
  end
  return out
end

---@param a table|nil
---@param b table|nil
local function union(a, b)
  if a == nil or b == nil then return nil end
  local out = {}
  for k in pairs(a) do out[k] = true end
  for k in pairs(b) do out[k] = true end
  return out
end

---@param node table source AST
---@param eval fun(ast: table): any evaluates expressions inside sources (`this.file.link`)
---@return FeySourceResult
function Store:source(node, eval)
  local t = node.t
  local vault = self.vault

  if t == 'label' then
    local rows = vault:query(
      [[SELECT DISTINCT f.path FROM labels l JOIN files f ON f.id = l.file_id
        WHERE l.label = :l OR l.label LIKE :p ESCAPE '\']],
      { l = node.v, p = like_escape(node.v) .. '/%' }
    )
    return { set = to_set(rows, 'path') }
  end

  if t == 'folder' then
    local folder = node.v:gsub('^%./', ''):gsub('/+$', '')
    if folder == '' then return { set = {} } end
    local rows = vault:query(
      [[SELECT path FROM files WHERE path = :f OR path LIKE :noext ESCAPE '\' OR path LIKE :p ESCAPE '\']],
      { f = folder, noext = like_escape(folder) .. '.%', p = like_escape(folder) .. '/%' }
    )
    return { set = to_set(rows, 'path') }
  end

  if t == 'incoming' or t == 'outgoing' then
    local target = node.target.t == 'link' and V.link(node.target.v) or eval(node.target)
    local path = self:path_of(target)
    if not path then return { set = {} } end
    if t == 'incoming' then
      local rows = vault:query(
        [[SELECT DISTINCT f.path FROM links l JOIN files f ON f.id = l.file_id WHERE l.target_file = :p]],
        { p = path }
      )
      return { set = to_set(rows, 'path') }
    end
    local rows = vault:query(
      [[SELECT DISTINCT l.target_file AS path FROM links l JOIN files f ON f.id = l.file_id
        WHERE f.path = :p AND l.target_file IS NOT NULL]],
      { p = path }
    )
    self:pages()
    local set = {}
    for k in pairs(to_set(rows, 'path')) do
      if self.page_by_path[k] then set[k] = true end
    end
    return { set = set }
  end

  if t == 'objects' then
    if node.v == 'section' or node.v == 'heading' then return { kind = 'section' } end
    if node.v == 'page' then return { kind = 'page' } end
    error(('query: unknown object type @%s'):format(node.v), 0)
  end

  if t == 'and' or t == 'or' then
    local l, r = self:source(node.l, eval), self:source(node.r, eval)
    local combine = t == 'and' and intersect or union
    return { set = combine(l.set, r.set), kind = l.kind or r.kind }
  end

  if t == 'not' then
    local inner = self:source(node.e, eval)
    self:pages()
    local set = {}
    for path in pairs(self.page_by_path) do
      if inner.set == nil or not inner.set[path] then set[path] = true end
    end
    return { set = set, kind = inner.kind }
  end
  error('query: unsupported source', 0)
end

-- Sections ---------------------------------------------------------------------------

---@param page table
---@param h table heading row
function Store:section_object(page, h)
  local path = rawget(page, '__path')
  local data = decode(h.data)
  local parent_title
  if h.parent_ord then
    local siblings = self:_headings()[path] or {}
    local p = siblings[h.parent_ord]
    parent_title = p and p.title
  end
  return lazy(function(t, k)
    if k == 'file' then return page.file end
    if k == 'title' then return h.title end
    if k == 'level' then return h.level end
    if k == 'signature' then return h.signature end
    if k == 'line' then return h.line end
    if k == 'end_line' or k == 'endline' then return h.end_line end
    if k == 'outline' then return h.outline end
    if k == 'parent' then return parent_title or NULL end
    if k == 'link' then return V.link(path, h.title, h.signature) end
    if k == 'labels' then
      self:_labels()
      return V.list(vim.deepcopy(self.section_labels[path .. '\0' .. h.ord] or {}))
    end
    if V.is_object(data) then
      local v = data[k]
      if v ~= nil then return v end
    end
    return nil
  end, function()
    local keys = { 'end_line', 'file', 'labels', 'level', 'line', 'link', 'outline', 'parent', 'signature', 'title' }
    if V.is_object(data) then vim.list_extend(keys, V.keys(data)) end
    return keys
  end, { __path = path })
end

---@param pages table[]
---@return table[]
function Store:sections_of(pages)
  local out = {}
  for _, page in ipairs(pages) do
    for _, h in ipairs(self:_headings()[rawget(page, '__path')] or {}) do
      out[#out + 1] = self:section_object(page, h)
    end
  end
  return out
end

return M
