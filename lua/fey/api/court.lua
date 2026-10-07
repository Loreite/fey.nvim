local FeyVault = require('fey.api.vault')
local court = require('fey.hollow.court')

---The court, the top of the tree of hollows: the registry of every hollow and the merged view of their vaults.
---Rows of the merged functions carry `hollow` (the id of the hollow, `court:notes`) and `abs` (the file to write to).
---@class FeyApiCourt
local FeyCourt = {}

---The court directory, nil when the court is switched off
---@return string|nil
function FeyCourt.root() return court.root() end

---The agenda directory of the court
---@return string|nil
function FeyCourt.agenda_dir() return court.agenda_dir() end

---The vault of the court (its own notes, the agenda files)
---@return FeyApiVault|nil
function FeyCourt.vault()
  local vault = court.vault()
  return vault and FeyVault._new(vault) or nil
end

---The hollows registered with the court: name, root, link and whether the directory is still there
---@return FeyHollowEntry[]
function FeyCourt.list() return court.list() end

---Every hollow of the tree (the court first) with its vault and its id (`court:notes`)
---@return { id: string, root: string, court: boolean, vault: FeyApiVault }[]
function FeyCourt.hollows()
  local out = {}
  for _, v in ipairs(court.hollows()) do
    out[#out + 1] = { id = v.id, root = v.root, court = v.court, vault = FeyVault._new(v.vault) }
  end
  return out
end

---The vault of a hollow of the tree, by id (`court:notes`) or by its name in the court
---@param name string
---@return FeyApiVault|nil
function FeyCourt.get(name)
  local v = court.find(name)
  return v and FeyVault._new(v.vault) or nil
end

---Register a hollow (done by itself when a hollow is attached)
---@param root string
---@param name? string
---@return string|nil name
---@return string|nil err
function FeyCourt.register(root, name) return court.register(root, name) end

---@param name string
---@return boolean removed
function FeyCourt.unregister(name) return court.unregister(name) end

---Remove the registrations of hollows that no longer exist, in every hollow of the tree
---@return string[] removed ids
function FeyCourt.prune() return court.prune() end

---Dates of every hollow, ordered by start; see `FeyApiVault:dates`
---@param opts? table
---@return table[]
function FeyCourt.dates(opts) return court.dates(opts) end

---Tasks of every hollow; see `FeyApiVault:tasks`
---@param opts? table
---@return table[]
function FeyCourt.tasks(opts) return court.tasks(opts) end

---Labels of every hollow with their file counts and the hollows they are in
---@param opts? { level?: 'file'|'heading', container?: string }
---@return { label: string, count: integer, hollows: string[] }[]
function FeyCourt.labels(opts) return court.labels(opts) end

---A statement run against the vault of every hollow, the rows together with their `hollow`
---@param sql string
---@param params? table
---@return table[]
function FeyCourt.query(sql, params) return court.query(sql, params) end

---Absolute path of a file of a hollow of the merged view
---@param name string
---@param path string
---@return string|nil
function FeyCourt.abs(name, path) return court.abs(name, path) end

---Update the index of every hollow in the background
---@param on_done? fun()
function FeyCourt.refresh(on_done) return court.refresh(on_done) end

---Open a hollow, optionally in a new tab and with the working directory set to it
---@param name string
---@param opts? { cwd?: boolean, tab?: boolean }
function FeyCourt.jump(name, opts) return court.jump(name, opts) end

return FeyCourt
