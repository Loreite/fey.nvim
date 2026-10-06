local FeyHeading = require('fey.api.heading')

---@class FeyApiFile
---@field vault FeyApiVault
---@field path string path relative to the vault root
---@field abs string absolute path
---@field title string
---@field mtime integer modification time in milliseconds when it was indexed
---@field size integer
---@field errors? string[] problems found while indexing (syntax errors, bad data)
---@field data any the document data value (a table for most notes)
---@field labels string[] all labels of the file
---@field headings FeyApiHeading[]
---@field tags table[] every syntactic tag of the file: `name`, `kind`, `line`, `vals`, `attrs`
---@field links table[] links and section tags written in the file
---@field backlinks table[] links from other files to this file
local FeyFile = {}

local lazy = {}

local function decode(s)
  if s == nil then return nil end
  local ok, v = pcall(vim.json.decode, s, { luanil = { object = true, array = true } })
  return ok and v or nil
end

function lazy.data(self)
  local row = self.vault:query('SELECT data FROM files WHERE path = :p', { p = self.path })[1]
  return row and decode(row.data)
end

function lazy.labels(self)
  local rows = self.vault:query(
    [[SELECT DISTINCT l.label FROM labels l JOIN files f ON f.id = l.file_id
      WHERE f.path = :p ORDER BY l.label]],
    { p = self.path }
  )
  return vim.tbl_map(function(r) return r.label end, rows)
end

function lazy.headings(self)
  local by_ord = {}
  local labels = self.vault:query(
    [[SELECT l.heading_ord, l.label FROM labels l JOIN files f ON f.id = l.file_id
      WHERE f.path = :p AND l.heading_ord IS NOT NULL]],
    { p = self.path }
  )
  for _, r in ipairs(labels) do
    by_ord[r.heading_ord] = by_ord[r.heading_ord] or {}
    table.insert(by_ord[r.heading_ord], r.label)
  end
  local out = {}
  for _, row in ipairs(self.vault:headings(self.path)) do
    out[row.ord] = FeyHeading._new(self, row, by_ord[row.ord] or {})
  end
  return out
end

function lazy.tags(self)
  local rows = self.vault:query(
    [[SELECT t.* FROM tags t JOIN files f ON f.id = t.file_id WHERE f.path = :p ORDER BY t.line]],
    { p = self.path }
  )
  for _, r in ipairs(rows) do
    r.vals, r.attrs = decode(r.vals) or {}, decode(r.attrs) or {}
  end
  return rows
end

function lazy.links(self) return self.vault:links(self.path) end

function lazy.backlinks(self) return self.vault:backlinks(self.path) end

FeyFile.__index = function(self, key)
  local fn = lazy[key]
  if fn then
    local value = fn(self)
    rawset(self, key, value)
    return value
  end
  return FeyFile[key]
end

---@private
---@param vault FeyApiVault
---@param row table row of the `files` table
---@return FeyApiFile
function FeyFile._new(vault, row)
  local errors = row.errors
  if type(errors) == 'string' then errors = decode(errors) end
  return setmetatable({
    vault = vault,
    path = row.path,
    abs = vim.fs.joinpath(vault.root, row.path),
    title = row.title,
    mtime = row.mtime,
    size = row.size,
    errors = errors,
  }, FeyFile)
end

---Value of a top level property (a key of the document data), nil when missing
---@param key string
---@return any
function FeyFile:property(key)
  local data = self.data
  if type(data) ~= 'table' or vim.islist(data) then return nil end
  return data[key]
end

---Write a property into the file (nil removes it) and update the index.
---The value goes where the property already lives: an attribute of a `table` tag, a bullet in
---its body or a `{# value #}` section. New properties are added to the first `table` tag.
---@param key string
---@param value any string, number, boolean or a list of those
---@return boolean ok
---@return string|nil err
function FeyFile:set_property(key, value)
  local ok, err = require('fey.db.source_edit').set(self.vault._vault, self.path, key, value)
  if ok then self:reload() end
  return ok, err
end

---Remove a property
---@param key string
---@return boolean ok
---@return string|nil err
function FeyFile:remove_property(key) return self:set_property(key, nil) end

---Add a label by extending the `labels` property
---@param label string
---@return boolean ok
---@return string|nil err
function FeyFile:add_label(label)
  local current = self:property('labels')
  local list = {}
  if type(current) == 'table' then list = vim.deepcopy(current) elseif type(current) == 'string' then list = { current } end
  for _, l in ipairs(list) do
    if tostring(l):lower() == label:lower() then return true end
  end
  list[#list + 1] = label
  return self:set_property('labels', list)
end

---Remove a label from the `labels` property. Labels given by `{# labels, ... #}` tags are
---not touched, edit the tag for those.
---@param label string
---@return boolean ok
---@return string|nil err
function FeyFile:remove_label(label)
  local current = self:property('labels')
  if type(current) ~= 'table' then return false, 'the file has no labels property' end
  local list = {}
  for _, l in ipairs(current) do
    if tostring(l):lower() ~= label:lower() then list[#list + 1] = l end
  end
  if #list == #current then return false, 'label is not part of the labels property' end
  return self:set_property('labels', #list > 0 and list or nil)
end

---Forget what was read, so the next access reads the index again (call after the index changed)
---@return FeyApiFile
function FeyFile:reload()
  for key in pairs(lazy) do
    rawset(self, key, nil)
  end
  local row = self.vault:query('SELECT * FROM files WHERE path = :p', { p = self.path })[1]
  if row then
    self.title, self.mtime, self.size = row.title, row.mtime, row.size
    local errors = row.errors
    self.errors = type(errors) == 'string' and decode(errors) or nil
  end
  return self
end

---The source text, from the buffer when the file is open
---@return string
function FeyFile:read()
  local bufnr = vim.fn.bufnr(self.abs)
  if bufnr > 0 and vim.api.nvim_buf_is_loaded(bufnr) then
    return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
  end
  local fh = assert(io.open(self.abs, 'rb'))
  local src = fh:read('*a')
  fh:close()
  return src
end

---Open the file
---@param mode? 'split'|'vsplit'|'tab'|'current' default 'current'
function FeyFile:open(mode)
  local cmd = ({ split = 'split', vsplit = 'vsplit', tab = 'tabedit', current = 'edit' })[mode or 'current'] or 'edit'
  vim.cmd(cmd .. ' ' .. vim.fn.fnameescape(self.abs))
end

return FeyFile
