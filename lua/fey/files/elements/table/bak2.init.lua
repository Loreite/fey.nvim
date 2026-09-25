local Range = require('fey.files.elements.range')
local TableRow = require('fey.files.elements.table.row')
local TableCell = require('fey.files.elements.table.cell')
local ts_utils = require('fey.utils.treesitter')
local config = require('fey.config')
local utils = require('fey.utils')

---@class FeyTable
---@field logical_grid FeyTableCell[][] 2D array mapping (row_idx, col_idx) to a Cell reference
---@field node_lookup table
---@field col_widths number[]
---@field rows FeyTableRow[]
---@field range FeyRange
---@field start_line integer
---@field start_col integer
---@field end_line integer
---@field node TSNode
local Table = {}

---@param range FeyRange
function Table:new(range)
  local data = {
    logical_grid = {},
    node_map = {},
    col_widths = {},
    rows = {},
    range = range,
    start_line = range.start_line,
    start_col = range.start_col,
    end_line = range.end_line,
    col_count = 0,
  }

  setmetatable(data, self)
  self.__index = self
  return data
end

---@param cursor? table
---@return FeyTable | nil
function Table.from_current_node(cursor)
  if not cursor then
    cursor = vim.api.nvim_win_get_cursor(0)
    cursor[2] = vim.fn.col('$')
  end

  local node = ts_utils.get_node_at_cursor(cursor)
  if not node then return nil end
  if node:type() ~= 'table' then node = ts_utils.closest_node(node, 'table') end
  if not node then return nil end

  local bufnr = vim.api.nvim_get_current_buf()
  local tbl = Table:new(Range.from_node(node))
  tbl.node = node

  local current_physical_rows = {}
  local current_top_boundary = nil
  local has_seen_crown = false
  local is_meta_row_mode = false

  local function commit_logical_row()
    if #current_physical_rows == 0 then return end

    local is_merged_horizontally = {}
    local is_merged_vertically = {}

    -- Parse boundary row for '*' and '^' operators
    if current_top_boundary then
      print()
      -- local inner = vim.trim(current_top_boundary)
      -- if inner:sub(1, 1) == '|' and inner:sub(-1, -1) == '|' then inner = inner:sub(2) end
      -- -- if inner:sub(-1, -1) == '|' then inner = inner:sub(1, -2) end
      --
      -- local col_idx = 1
      -- local pos = 1
      -- while pos <= #inner do
      --   local char = inner:sub(pos, pos)
      --   if char == '+' or char == '*' then
      --     if char == '*' then is_merged_horizontally[col_idx + 1] = true end
      --     col_idx = col_idx + 1
      --   else
      --     local segment = inner:match('^([^+*]+)', pos)
      --     if segment then
      --       if segment:find('%^') then is_merged_vertically[col_idx] = true end
      --       pos = pos + #segment - 1
      --     end
      --   end
      --   pos = pos + 1
      -- end
    else
    end

    local current_row_idx = #tbl.logical_grid + 1
    local new_logical_row = {}
    local row_cells_unique = {}

    -- Parse physical text for the current block of rows
    local physical_lines = {}
    for _, phys_row in ipairs(current_physical_rows) do
      local line_cells = {}
      local c = 0
      for cell_node in phys_row:iter_children() do
        if cell_node:type() == 'cell' then
          c = c + 1
          local srow, scol = cell_node:start()
          tbl.node_lookup[string.format('%d%d', srow, scol)] = { r = current_row_idx, c = c }
          local content = ''
          local contents_field = cell_node:field('contents')
          if contents_field and #contents_field > 0 then content = vim.treesitter.get_node_text(contents_field[1], 0) end
          table.insert(line_cells, content)
        end
      end
      if base_col_count == 0 then base_col_count = #line_cells end
      table.insert(physical_lines, line_cells)
    end

    -- Map physical row data into the 2D abstract grid
    for l, phys_line in ipairs(physical_lines) do
      local phys_idx = 1
      for c = 1, base_col_count do
        local cell

        if is_merged_horizontally[c] then
          cell = new_logical_row[c - 1]
        elseif is_merged_vertically[c] and current_row_idx > 1 then
          cell = tbl.logical_grid[current_row_idx - 1][c]
          -- Extend rowspan only once per logical row block
          if l == 1 and not new_logical_row[c] then cell.rowspan = cell.rowspan + 1 end
        else
          if l == 1 then
            cell = TableCell:new({
              row_idx = current_row_idx,
              col_idx = c,
              lines = {},
              config = {},
            })
            -- Map forward to calculate total horizontal span
            local cs = 1
            local check_c = c + 1
            while check_c <= base_col_count and is_merged_horizontally[check_c] do
              cs = cs + 1
              check_c = check_c + 1
            end
            cell.colspan = cs
            table.insert(row_cells_unique, cell)
          else
            cell = new_logical_row[c]
          end
        end

        new_logical_row[c] = cell

        -- If it's the start column of a cell, consume physical text
        if not is_merged_horizontally[c] then
          local text = phys_line[phys_idx] or ''
          phys_idx = phys_idx + 1
          table.insert(cell.lines, text)
        end
      end
    end

    for _, cell in ipairs(row_cells_unique) do
      cell:update_display_len()
    end

    table.insert(tbl.logical_grid, new_logical_row)
    table.insert(tbl.rows, TableRow:new({ table = tbl, cells = row_cells_unique, line = current_row_idx }))
  end

  for child in node:iter_children() do
    local type = child:type()

    if type == 'row' then
      local cells = child:field('cell')
      if not has_seen_crown and tbl.col_count < 1 then tbl.col_count = #cells end
      table.insert(current_physical_rows, cells)
    elseif type == 'hr' then
      local boundary = { type = type }
      table.insert(tbl.logical_grid, boundary)
      current_top_boundary = boundary
    elseif utils.set({ 'cbi', 'cbo' })[type] then
      commit_logical_row()
      current_physical_rows = {}

      local spans = {}
      local span = 0
      for i, cell in ipairs(child:field('cb_cell')) do
        span = span + 1
        local text = vim.treesitter.get_node_text(cell, bufnr)
        if text:sub(-1, -1) == '+' then
          local vmerge = text:sub(1, 1) == '|' and text:sub(-2, -2) == '|'
          table.insert(spans, { span = span, start = i, vmerge = vmerge })
          span = 0
        end
      end
      table.insert(tbl.logical_grid, { type = type, spans = spans })
      current_top_boundary = spans

      if type == 'cbo' and not is_meta_row_mode then
        is_meta_row_mode = true
      elseif type == 'cbo' and is_meta_row_mode then
        is_meta_row_mode = false
      end

      if not has_seen_crown and #tbl.rows > 0 then has_seen_crown = true end
    end
  end
  commit_logical_row()

  return tbl
end

--- Calculates final column widths based on minw, maxw, auto rules, and contents.
function Table:calculate_widths(max_table_width)
  local col_count = #self.logical_grid[1]
  for c = 1, col_count do
    self.col_widths[c] = 3
  end -- Default min 3

  -- First pass: absolute widths
  for r, row_cells in ipairs(self.logical_grid) do
    for c, cell in ipairs(row_cells) do
      if cell.colspan == 1 then
        local w = cell.display_len
        if cell.config.minw and w < cell.config.minw then w = cell.config.minw end
        if cell.config.maxw and w > cell.config.maxw then w = cell.config.maxw end
        if w > self.col_widths[c] then self.col_widths[c] = w end
      end
    end
  end
  -- Second pass would distribute remainder based on 'auto: X%' or ratio ratios here.
end

--- Generates the string array for the table text.
function Table:draw()
  self:calculate_widths(120) -- 120 chars default max
  local lines = {}

  local function get_boundary_char(type, r, c, is_intersection)
    if is_intersection then
      -- If cells horizontally share an instance across this boundary, it's a merged column (*)
      local left = self.logical_grid[r] and self.logical_grid[r][c - 1]
      local right = self.logical_grid[r] and self.logical_grid[r][c]
      if left and right and left == right then return '*' end
      return '+'
    else
      -- If cells vertically share an instance across this boundary, it's a merged row (^)
      local top = self.logical_grid[r - 1] and self.logical_grid[r - 1][c]
      local bottom = self.logical_grid[r] and self.logical_grid[r][c]
      if top and bottom and top == bottom then return string.rep('^', self.col_widths[c] + 2) end

      if type == 'hr' then
        return string.rep('=', self.col_widths[c] + 2)
      elseif type == 'cbo' then
        return string.rep('-', self.col_widths[c] + 2)
      else
        return string.rep('~', self.col_widths[c] + 2)
      end
    end
  end

  for r = 1, #self.logical_grid do
    -- Determine if previous boundary was hr, cbo, or cbi
    local b_type = r == 1 and 'cbo' or 'cbi'
    -- 1. Draw Top Boundary Row
    local bound_line = '|'
    for c = 1, #self.logical_grid[r] do
      bound_line = bound_line .. get_boundary_char(b_type, r, c, false) .. get_boundary_char(b_type, r, c, true)
    end
    table.insert(lines, bound_line)

    -- 2. Draw Data Row (Handles multiline by checking max lines in this logical row)
    local max_lines = 1
    for c, cell in ipairs(self.logical_grid[r]) do
      max_lines = math.max(max_lines, #cell.lines)
    end

    for l = 1, max_lines do
      local text_line = '|'
      for c = 1, #self.logical_grid[r] do
        local cell = self.logical_grid[r][c]
        if self.logical_grid[r][c - 1] ~= cell then -- Only draw if it's the start of the cell
          local content = cell.lines[l] or ''
          local width = 0
          for span = 0, cell.colspan - 1 do
            width = width + self.col_widths[c + span] + (span > 0 and 3 or 0)
          end
          text_line = text_line .. string.format(' %-' .. width .. 's |', vim.trim(content))
        end
      end
      table.insert(lines, text_line)
    end
  end
  -- Draw final bottom cbo
  table.insert(lines, '|') -- Append calculated final bottom boundary similar to top boundary loop above

  return lines
end

function Table:reformat()
  if not self.node then return false end
  local _, start_col = self.node:range()
  local indent = config:get_indent(start_col, vim.api.nvim_get_current_buf())

  local contents = vim.tbl_map(function(line) return ('%s%s'):format(indent, line) end, self:draw())
  local view = vim.fn.winsaveview() or {}

  vim.api.nvim_buf_set_lines(0, self.range.start_line - 1, self.range.end_line - 1, false, contents)
  vim.fn.winrestview(view)
  return true
end

return Table
