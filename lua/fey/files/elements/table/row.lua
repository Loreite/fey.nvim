local Range = require('fey.files.elements.range')
local TableCell = require('fey.files.elements.table.cell')

---@class FeyTableRow
---@field table FeyTable
---@field cells FeyTableCell[] Array of unique cells originating in this row
---@field is_config_row boolean
---@field line number
local TableRow = {}

function TableRow:new(opts)
  local data = {
    table = opts.table,
    cells = opts.cells or {},
    is_config_row = opts.is_config_row or false,
    line = opts.line or 1,
    range = Range.from_line(opts.table.range.start_line + opts.line - 1),
  }
  setmetatable(data, self)
  self.__index = self
  return data
end

function TableRow:add_cell(cell)
  table.insert(self.cells, cell)
  return self
end

return TableRow
