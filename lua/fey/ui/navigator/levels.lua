-- The levels above a document in the navigator: the directories of a hollow, the hollows themselves, and
-- the court on top.
--
-- A level (a "loc") is one listing:
--
--   { kind = 'dir', path }            the Fey files and the directories of a directory
--   { kind = 'hollows', parent }      the hollows registered below the hollow `parent` (a root path); with
--                                     no parent the court alone, the top of the tree
--
-- Going up (`parent_loc`) climbs the directories to the root of a hollow. A hollow inside another hollow
-- keeps climbing through the directories of the hollow it lives in. A hollow with no hollow above it goes
-- up into the list of hollows of the court, with the cursor on it, and from there into the court itself.
local tree = require('fey.hollow.tree')
local court = require('fey.hollow.court')

local M = {}

---@class FeyNavLevelItem
---@field kind 'file'|'dir'|'hollow'
---@field label string
---@field path string absolute path (the root, for a hollow)
---@field hollow? boolean a directory that is the root of a hollow
---@field id? string canonical id of a hollow
---@field court? boolean the court itself
---@field ok? boolean the hollow is available

---@class FeyNavLoc
---@field kind 'dir'|'hollows'
---@field path? string
---@field parent? string

local function realpath(path) return tree.realpath(path) end

---@param path string
---@return string
local function dirname(path) return vim.fs.dirname(realpath(path)) end

---@param a FeyNavLevelItem
---@param b FeyNavLevelItem
local function by_name(a, b)
  if a.kind ~= b.kind then return a.kind == 'dir' end
  return a.label:lower() < b.label:lower()
end

---The Fey files and the directories of a directory (hidden entries, `.fey` included, are left out)
---@param path string
---@return FeyNavLevelItem[]
function M.dir_items(path)
  local out = {}
  if vim.fn.isdirectory(path) == 0 then return out end
  local ignore = {}
  for _, name in ipairs(require('fey.config').vault.ignore or {}) do
    ignore[name] = true
  end
  for name, kind in vim.fs.dir(path) do
    if name:sub(1, 1) ~= '.' and not ignore[name] then
      local full = vim.fs.joinpath(path, name)
      if kind == 'link' then
        local stat = vim.uv.fs_stat(full)
        kind = stat and stat.type or kind
      end
      if kind == 'directory' then
        out[#out + 1] = { kind = 'dir', label = name .. '/', path = full, hollow = tree.is_hollow(full) }
      elseif kind == 'file' and require('fey.utils').is_fey_file(name) then
        out[#out + 1] = { kind = 'file', label = name, path = full }
      end
    end
  end
  table.sort(out, by_name)
  return out
end

---The hollows registered below a hollow, or the court alone for no parent
---@param parent? string root of the hollow
---@return FeyNavLevelItem[]
function M.hollow_items(parent)
  local out = {}
  if not parent then
    local root = court.root()
    if root then
      out[1] = { kind = 'hollow', label = 'court', path = root, id = 'court', court = true, ok = tree.is_hollow(root) }
    end
    return out
  end
  local parent_id = tree.id_of(parent)
  for _, entry in ipairs(tree.entries(parent)) do
    if not entry.misplaced then
      out[#out + 1] = {
        kind = 'hollow',
        label = entry.name,
        path = entry.root,
        id = parent_id and (parent_id .. ':' .. entry.name) or nil,
        ok = entry.ok,
      }
    end
  end
  return out
end

---@param loc FeyNavLoc
---@return FeyNavLevelItem[]
function M.items(loc)
  if loc.kind == 'hollows' then return M.hollow_items(loc.parent) end
  return M.dir_items(loc.path)
end

---The hollow a registry hands a hollow to: the nearest hollow above it, else the court. Nil for the court.
---@param root string
---@return string|nil
local function registry_parent(root)
  if court.is_court(root) then return nil end
  return tree.registry_root_for(root)
end

---The level above a level, nil at the top
---@param loc FeyNavLoc
---@return FeyNavLoc|nil
function M.parent_loc(loc)
  if loc.kind == 'dir' then
    local path = realpath(loc.path)
    if tree.is_hollow(path) then
      if court.is_court(path) then return { kind = 'hollows' } end
      if tree.parent_root(path) then return { kind = 'dir', path = dirname(path) } end
      -- no hollow above: up into the hollows of the court
      local root = court.root()
      if not root then return nil end
      return { kind = 'hollows', parent = root }
    end
    local parent = dirname(path)
    if parent == path then return nil end
    return { kind = 'dir', path = parent }
  end
  -- hollows
  if not loc.parent then return nil end
  local up = registry_parent(loc.parent)
  if court.is_court(loc.parent) then return { kind = 'hollows' } end
  return { kind = 'hollows', parent = up }
end

---The path to put the cursor on in the parent listing of `loc`
---@param loc FeyNavLoc
---@return string|nil
function M.anchor_of(loc)
  if loc.kind == 'dir' then return loc.path end
  return loc.parent
end

---@param loc FeyNavLoc
---@return string
function M.key(loc)
  return loc.kind .. '\0' .. tostring(loc.path or loc.parent or '')
end

---The directory a document lives in
---@param bufnr integer
---@return string|nil
function M.dir_of_buffer(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == '' then return nil end
  return dirname(name)
end

---The level for the hollows next to the hollow a path is in (and the one to select), the court when it is
---in none
---@param path? string a file or directory, default the working directory
---@return FeyNavLoc loc
---@return string|nil select
function M.hollow_level_for(path)
  local root = tree.hollow_root_of(path or vim.fn.getcwd())
  if not root then return { kind = 'hollows' }, nil end
  if court.is_court(root) then return { kind = 'hollows' }, root end
  return { kind = 'hollows', parent = registry_parent(root) }, root
end

---Text for the title: where a level is
---@param loc FeyNavLoc
---@return string[] parts
function M.breadcrumb(loc)
  if loc.kind == 'hollows' then
    if not loc.parent then return { 'court' } end
    return { tree.id_of(loc.parent) or vim.fs.basename(loc.parent), 'hollows' }
  end
  local root = tree.hollow_root_of(loc.path)
  local id = root and tree.id_of(root)
  local parts = {}
  if root then
    parts[1] = id or vim.fs.basename(root)
    local rel = vim.fs.relpath(root, realpath(loc.path))
    if rel and rel ~= '.' and rel ~= '' then
      for part in rel:gmatch('[^/]+') do
        parts[#parts + 1] = part
      end
    end
  else
    parts[1] = loc.path
  end
  return parts
end

return M
