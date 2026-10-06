-- Export a database view as a Fey table (used by `feydb` tags).
local Model = require('fey.db.model')
local store = require('fey.db.store')
local render = require('fey.query.render')

local M = {}

---@class FeyDbExportSpec
---@field db string database name
---@field view? string view name (the first view when omitted)
---@field rows? integer how many rows to include

---@param vault FeyVault
---@param spec FeyDbExportSpec
---@param opts? FeyQueryRenderOpts
---@return string[] lines
function M.table_lines(vault, spec, opts)
  if not spec.db or spec.db == '' then error('feydb: name a database, e.g. {# feydb, 10; db: projects #}', 0) end
  local base, err = store.load(vault, spec.db)
  if not base then error('feydb: ' .. tostring(err), 0) end

  local view
  if spec.view and spec.view ~= '' then
    for _, v in ipairs(base.views) do
      if v.name:lower() == spec.view:lower() then view = v end
    end
    if not view then error(('feydb: database %s has no view named %s'):format(spec.db, spec.view), 0) end
  else
    view = base.views[1]
  end

  local model = Model.new(vault, base)
  local res = model:compute(view)
  if res.error then error('feydb: ' .. res.error, 0) end

  local headers = {}
  local getters = {}
  local group_get
  if view.group and view.group.prop then
    headers[1] = view.group.prop
    group_get = model:getter(view.group.prop)
  end
  for _, col in ipairs(view.columns) do
    local title = col.display
    if not title or title == '' then
      for _, p in ipairs(base.properties or {}) do
        if p.name == col.prop and p.display and p.display ~= '' then title = p.display end
      end
    end
    headers[#headers + 1] = title or col.prop
    getters[#getters + 1] = model:getter(col.prop)
  end

  local limit = spec.rows or #res.rows
  local rows = {}
  for i = 1, math.min(limit, #res.rows) do
    local row, cells = res.rows[i], {}
    if group_get then cells[1] = group_get(row) end
    for _, get in ipairs(getters) do
      cells[#cells + 1] = get(row)
    end
    rows[i] = cells
  end

  return render.lines({ type = 'table', headers = headers, rows = rows, count = #rows, grouped = false }, opts)
end

return M
