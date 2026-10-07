-- The tree of hollows.
--
-- A hollow is a directory with a `.fey` folder. Its vault is the database in that folder, the index of its
-- notes. Hollows nest: a hollow inside the directory of another is a subhollow. The files of a hollow are
-- the Fey files below its root up to the first directory that has a `.fey` folder of its own, which is
-- another hollow and is left alone.
--
-- Every hollow registers with its NEAREST ancestor hollow, the one it lives in. Only a hollow with no hollow
-- above it, up to the root of the file system, registers with the court (the hollow of `fey_court_dir`).
-- A registration is a symbolic link in the registry of the parent, `<parent>/.fey/hollows/<name>`, that
-- points at the hollow root. So the hollows form a tree, with the court at the top, and every hollow has a
-- canonical id, the names from the court down:
--
--   court                   the court
--   court:notes             a hollow registered with the court
--   court:notes:history     a hollow registered with `notes`
--
-- A name is unique in its registry. It comes from the setting `name` of the hollow (see below), else from
-- the name of its directory, and gets a number when it is taken.
--
-- Settings of a hollow are in its own `.fey/hollow.fey`, a Fey data file:
--
--   {# table; name: notes; merge: false #}
--
--   name   the name it registers with
--   merge  false keeps the hollow, and what is below it, out of the merged views of the hollows above it
--          (the court agenda, a `tree` or `court` scope). Default true. The hollow itself still sees its
--          own data.
--
-- References name a hollow and a file in it, `court:notes:history/a.fey`: a keyword (`court`, or
-- `current` for the hollow the reference is written in), the names down to the hollow, and after the first
-- `/` the path inside it. `court/agenda/inbox.fey` is a file of the court. A text that does not start with
-- one of the keywords is not a reference (write `./court/x.fey` for a folder named court).
local M = {}

local uv = vim.uv

local function conf() return require('fey.config') end

---@param path string
---@return string
function M.realpath(path) return uv.fs_realpath(path) or vim.fs.normalize(path) end

---@return string
local function dirname() return conf().vault.dirname end

---Is `root` the root of a hollow
---@param root string
---@return boolean
function M.is_hollow(root) return vim.fn.isdirectory(vim.fs.joinpath(root, dirname())) == 1 end

---The nearest hollow above a directory (not the directory itself), up to the root of the file system
---@param root string
---@return string|nil
function M.parent_root(root)
  local dir = vim.fs.dirname(M.realpath(root))
  local last
  while dir and dir ~= last do
    if M.is_hollow(dir) then return dir end
    last = dir
    dir = vim.fs.dirname(dir)
  end
end

---The hollows above a directory, the nearest first
---@param root string
---@return string[]
function M.ancestors(root)
  local out = {}
  local current = root
  while true do
    local parent = M.parent_root(current)
    if not parent then return out end
    out[#out + 1] = parent
    current = parent
  end
end

---The root of the hollow a file or directory belongs to: the nearest directory at or above it with a
---hollow folder
---@param path string
---@return string|nil
function M.hollow_root_of(path)
  path = M.realpath(path)
  local stat = uv.fs_stat(path)
  local dir = (stat and stat.type == 'directory') and path or vim.fs.dirname(path)
  local last
  while dir and dir ~= last do
    if M.is_hollow(dir) then return dir end
    last = dir
    dir = vim.fs.dirname(dir)
  end
end

-- Settings ---------------------------------------------------------------------------------

---@class FeyHollowSettings
---@field name? string
---@field merge boolean

local settings_cache = {}

---@param root string
---@return string
function M.settings_path(root) return vim.fs.joinpath(root, dirname(), 'hollow.fey') end

---The settings of a hollow (the file is read again when it changed)
---@param root string
---@return FeyHollowSettings
function M.settings(root)
  local path = M.settings_path(root)
  local stat = uv.fs_stat(path)
  local defaults = { merge = true }
  if not stat then return defaults end
  local key = stat.mtime.sec .. ':' .. stat.mtime.nsec .. ':' .. stat.size
  local hit = settings_cache[path]
  if hit and hit.key == key then return hit.settings end

  local settings = defaults
  local fh = io.open(path, 'rb')
  local src = fh and fh:read('*a')
  if fh then fh:close() end
  if src and pcall(vim.treesitter.language.add, 'fey') then
    local ok, meta = pcall(require('fey.vault.extract').extract, src, {})
    local data = ok and meta.data
    if type(data) == 'table' and not vim.islist(data) then
      settings = {
        name = type(data.name) == 'string' and data.name ~= '' and data.name or nil,
        merge = data.merge ~= false,
      }
    end
  end
  settings_cache[path] = { key = key, settings = settings }
  return settings
end

---Write the settings of a hollow. The file is ours: it holds one table tag, anything else in it is replaced.
---@param root string
---@param settings table `name` and `merge`; nil values are left out
---@return boolean ok
---@return string|nil err
function M.write_settings(root, settings)
  local key_values = {}
  if settings.name then key_values.name = settings.name end
  if settings.merge == false then key_values.merge = 'false' end
  local path = M.settings_path(root)
  if next(key_values) == nil then
    if uv.fs_stat(path) then uv.fs_unlink(path) end
    return true
  end
  local text, err = require('fey.files.elements.tags.edit').build('table', {}, key_values, { order = { 'name', 'merge' } })
  if not text then return false, err end
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  local fh, open_err = io.open(path, 'w')
  if not fh then return false, tostring(open_err) end
  fh:write(text, '\n')
  fh:close()
  settings_cache[path] = nil
  return true
end

-- The registry of a hollow ---------------------------------------------------------------------

---@class FeyHollowEntry
---@field name string the name in the registry
---@field root string absolute path of the hollow
---@field link string where the registration is
---@field ok boolean the hollow directory exists
---@field misplaced boolean the hollow has a nearer ancestor hollow, it belongs in the registry of that one

---Directory of the registrations of the hollows below a hollow
---@param root string
---@return string
function M.registry_dir(root) return vim.fs.joinpath(root, dirname(), 'hollows') end

---Where a link points
---@param path string the link, or the `.link` file
---@return string|nil
local function read_target(path)
  local target = uv.fs_readlink(path)
  if target then
    if target:sub(1, 1) ~= '/' then target = vim.fs.joinpath(vim.fs.dirname(path), target) end
    return vim.fs.normalize(target)
  end
  local fh = io.open(path, 'r')
  if fh then
    local line = fh:read('*l')
    fh:close()
    if line and line ~= '' then return vim.fs.normalize(line) end
  end
end

---The registry a hollow belongs in: the nearest hollow above it, else the court hollow
---@param root string
---@return string|nil
function M.registry_root_for(root)
  local parent = M.parent_root(root)
  if parent then return parent end
  return require('fey.hollow.court').root()
end

---The registrations in the registry of a hollow, ordered by name
---@param registry_root string
---@return FeyHollowEntry[]
function M.entries(registry_root)
  local dir = M.registry_dir(registry_root)
  local out = {}
  if vim.fn.isdirectory(dir) == 0 then return out end
  local here = M.realpath(registry_root)
  for name, kind in vim.fs.dir(dir) do
    if kind == 'link' or kind == 'file' then
      local link = vim.fs.joinpath(dir, name)
      local target = read_target(link)
      if target then
        local ok = M.is_hollow(target)
        out[#out + 1] = {
          name = (name:gsub('%.link$', '')),
          root = target,
          link = link,
          ok = ok,
          misplaced = ok and M.registry_root_for(target) ~= here,
        }
      end
    end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

---The hollows directly below a hollow, available and registered where they belong
---@param root string
---@param opts? { merged?: boolean } `merged`: leave out the hollows that opted out of merged views
---@return FeyHollowEntry[]
function M.children(root, opts)
  opts = opts or {}
  local out = {}
  for _, entry in ipairs(M.entries(root)) do
    if entry.ok and not entry.misplaced and (not opts.merged or M.settings(entry.root).merge) then
      out[#out + 1] = entry
    end
  end
  return out
end

---The name a hollow has in a registry
---@param registry_root string
---@param root string
---@return string|nil
function M.name_in(registry_root, root)
  root = M.realpath(root)
  for _, entry in ipairs(M.entries(registry_root)) do
    if entry.ok and M.realpath(entry.root) == root then return entry.name end
  end
end

---Can `name` be a hollow name in a registry?
---@param registry_root string
---@param name string
---@return boolean ok
---@return string|nil err
function M.valid_name(registry_root, name)
  if name == '' or not name:match('^[%w_.%-]+$') then
    return false, 'a name has letters, digits, `_`, `-` and `.`'
  end
  if name == 'court' or name == 'current' then return false, name .. ' is a keyword' end
  for _, entry in ipairs(M.entries(registry_root)) do
    if entry.name == name then return false, 'there is already a hollow named ' .. name end
  end
  return true
end

---Register a hollow with the hollow it lives in (the nearest hollow above it), or with the court hollow when
---there is none. Registering a hollow twice does nothing.
---@param root string
---@param name? string the name, else the `name` setting of the hollow, else its directory name
---@return string|nil name the name it is registered with
---@return string|nil err
function M.register(root, name)
  root = M.realpath(root)
  local court = require('fey.hollow.court')
  if court.is_court(root) then return nil end
  local registry_root = M.registry_root_for(root)
  if not registry_root then return nil end
  -- the court hollow is created by its setup (or by using the merged view), not by attaching a hollow
  if registry_root == court.root() and vim.fn.isdirectory(M.registry_dir(registry_root)) == 0 then return nil end

  local existing = M.name_in(registry_root, root)
  if existing then return existing end

  local entries = M.entries(registry_root)
  local taken = { court = true, current = true }
  for _, entry in ipairs(entries) do
    taken[entry.name] = true
  end
  local base = name or M.settings(root).name or vim.fs.basename(root)
  base = base:gsub('[^%w_.%-]', '_')
  local candidate, n = base, 1
  while taken[candidate] do
    n = n + 1
    candidate = ('%s-%d'):format(base, n)
  end

  vim.fn.mkdir(M.registry_dir(registry_root), 'p')
  local link = vim.fs.joinpath(M.registry_dir(registry_root), candidate)
  if not uv.fs_symlink(root, link, { dir = true }) then
    -- no symbolic links (Windows without the right): a file with the path
    local fh, err = io.open(link .. '.link', 'w')
    if not fh then return nil, tostring(err) end
    fh:write(root, '\n')
    fh:close()
  end
  return candidate
end

---Register a hollow and every hollow above it, outermost first, so the chain from the court hollow is whole
---@param root string
function M.register_chain(root)
  local chain = M.ancestors(root)
  for i = #chain, 1, -1 do
    M.register(chain[i])
  end
  M.register(root)
end

---Remove a registration (the hollow itself is not touched)
---@param registry_root string
---@param name string
---@return boolean removed
function M.unregister(registry_root, name)
  for _, entry in ipairs(M.entries(registry_root)) do
    if entry.name == name then return uv.fs_unlink(entry.link) and true or false end
  end
  return false
end

---Remove the registrations of a registry that point at hollows that are gone, or belong in another registry
---@param registry_root string
---@return string[] removed names
function M.prune(registry_root)
  local removed = {}
  for _, entry in ipairs(M.entries(registry_root)) do
    if (not entry.ok or entry.misplaced) and uv.fs_unlink(entry.link) then removed[#removed + 1] = entry.name end
  end
  return removed
end

-- Ids and references ---------------------------------------------------------------------------

---The canonical id of a hollow: `court`, `court:notes`, `court:notes:history`. Nil while the chain of
---registrations from the court hollow is not whole.
---@param root string
---@return string|nil
function M.id_of(root)
  root = M.realpath(root)
  local court = require('fey.hollow.court')
  if court.is_court(root) then return 'court' end
  local registry_root = M.registry_root_for(root)
  if not registry_root then return nil end
  local name = M.name_in(registry_root, root)
  if not name then return nil end
  local parent_id = M.id_of(registry_root)
  return parent_id and (parent_id .. ':' .. name) or nil
end

---@class FeyHollowRef
---@field keyword 'court'|'current'
---@field names string[] the hollows below the keyword
---@field path? string the file in the hollow

---Read a reference, nil when the text is not one
---@param text string
---@return FeyHollowRef|nil
function M.parse_ref(text)
  local slash = text:find('/', 1, true)
  local head = slash and text:sub(1, slash - 1) or text
  local parts = vim.split(head, ':', { plain = true })
  if parts[1] ~= 'court' and parts[1] ~= 'current' then return nil end
  local names = {}
  for i = 2, #parts do
    if not parts[i]:match('^[%w_.%-]+$') then return nil end
    names[#names + 1] = parts[i]
  end
  local path = slash and text:sub(slash + 1) or nil
  if path == '' then path = nil end
  return { keyword = parts[1], names = names, path = path }
end

---The root of the hollow a reference names, and the path in it
---@param ref string|FeyHollowRef
---@param from_root? string the hollow the reference is written in, for `current`
---@return string|nil root
---@return string|nil path
---@return string|nil err
function M.resolve_ref(ref, from_root)
  if type(ref) == 'string' then
    local parsed = M.parse_ref(ref)
    if not parsed then return nil, nil, 'not a hollow reference: ' .. ref end
    ref = parsed
  end
  local root
  if ref.keyword == 'court' then
    root = require('fey.hollow.court').root()
    if not root then return nil, nil, 'the court is switched off' end
  else
    if not from_root then return nil, nil, 'no current hollow' end
    root = M.realpath(from_root)
  end
  for _, name in ipairs(ref.names) do
    local found
    for _, entry in ipairs(M.entries(root)) do
      if entry.name == name and entry.ok then found = entry end
    end
    if not found then return nil, nil, ('no hollow named %s in %s'):format(name, M.id_of(root) or root) end
    root = M.realpath(found.root)
  end
  return root, ref.path
end

---A reference to a file of a hollow, as written from another hollow: the plain path inside the same hollow,
---else the canonical id of the hollow and the path
---@param root string the hollow of the file
---@param path string
---@param from_root? string the hollow the reference is written in
---@return string|nil ref nil when the hollow has no id
function M.format_ref(root, path, from_root)
  if from_root and M.realpath(from_root) == M.realpath(root) then return path end
  local id = M.id_of(root)
  return id and (id .. '/' .. path) or nil
end

return M
