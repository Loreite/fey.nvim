local utils = require('fey.utils')

---@class FeyTableCell
---@field row_idx number Logical row index in the abstract grid
---@field col_idx number Logical column index in the abstract grid
---@field rowspan number
---@field colspan number
---@field lines string[] Multi-line content
---@field display_len number Max width among all lines
---@field range FeyRange[cite: 1]
---@field config table Parsed configuration (e.g., maxw, minw, auto)
---@field wrapped table
local TableCell = {}

function TableCell:new(opts)
  local data = {
    row_idx = opts.row_idx,
    col_idx = opts.col_idx,
    rowspan = opts.rowspan or 1,
    colspan = opts.colspan or 1,
    lines = opts.lines or { '' },
    display_len = 0,
    config = opts.config or {},
    range = opts.range,
    wrapped = {},
  }
  setmetatable(data, self)
  self.__index = self
  data:update_display_len()
  return data
end

function TableCell:update_display_len()
  self.display_len = 0
  for _, line in ipairs(self.lines) do
    local len = vim.api.nvim_strwidth(vim.trim(line))
    if len > self.display_len then self.display_len = len end
  end
end

--- Parses 'key: value' configs from the cell lines if it resides in the config block
function TableCell:parse_config()
  for _, line in ipairs(self.lines) do
    local k, v = line:match('([%w_]+):%s*(.+)')
    if k and v then
      if k == 'maxw' or k == 'minw' then
        self.config[k] = tonumber(v)
      elseif k == 'auto' then
        self.config[k] = v -- can be a number string or "10%"
      end
    end
  end
end

return TableCell
