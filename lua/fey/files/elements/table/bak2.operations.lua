local TableOps = {}

-- Helper to safely get the table and cursor logical position
local function get_ctx()
  local ts_utils = require('fey.utils.treesitter')
  local tbl = require('fey.files.elements.table').from_current_node()
  if not tbl then return nil, 1, 1 end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local node = ts_utils.get_node_at_cursor(cursor)

  -- Escalate to the closest 'cell' node if the cursor is on nested content
  if node and node:type() ~= 'cell' then node = ts_utils.closest_node(node, 'cell') end

  local r, c = 1, 1

  if node and node:type() == 'cell' then
    local start_row, start_col = node:range()
    -- Formulate the exact same key used during parsing
    local key = string.format('%d,%d', start_row, start_col)

    if tbl.node_lookup and tbl.node_lookup[key] then
      r = tbl.node_lookup[key].r
      c = tbl.node_lookup[key].c
    end
  end

  return tbl, r, c
end

function TableOps.reformat()
  local tbl = get_ctx()
  if not tbl then return end

  tbl:reformat()
end

function TableOps.insert_row_before()
  local tbl, r, _ = get_ctx()
  if not tbl then return end

  local new_row = {}
  for i = 1, #tbl.logical_grid[1] do
    table.insert(new_row, require('fey.files.elements.table.cell'):new({ row_idx = r, col_idx = i }))
  end
  table.insert(tbl.logical_grid, r, new_row)
  tbl:reformat()
end

function TableOps.insert_row_after()
  local tbl, r, _ = get_ctx()
  if not tbl then return end

  local new_row = {}
  for i = 1, #tbl.logical_grid[1] do
    table.insert(new_row, require('fey.files.elements.table.cell'):new({ row_idx = r + 1, col_idx = i }))
  end
  table.insert(tbl.logical_grid, r + 1, new_row)
  tbl:reformat()
end

function TableOps.delete_row()
  local tbl, r, _ = get_ctx()
  if not tbl then return end

  table.remove(tbl.logical_grid, r)
  tbl:reformat()
end

function TableOps.move_row_up()
  local tbl, r, _ = get_ctx()
  if not tbl then return end

  if r > 1 then
    tbl.logical_grid[r], tbl.logical_grid[r - 1] = tbl.logical_grid[r - 1], tbl.logical_grid[r]
    tbl:reformat()
  end
end

function TableOps.move_row_down()
  local tbl, r, _ = get_ctx()
  if not tbl then return end

  if r < #tbl.logical_grid then
    tbl.logical_grid[r], tbl.logical_grid[r + 1] = tbl.logical_grid[r + 1], tbl.logical_grid[r]
    tbl:reformat()
  end
end

function TableOps.insert_col_before()
  local tbl, _, c = get_ctx()
  if not tbl then return end

  for row_idx, row in ipairs(tbl.logical_grid) do
    table.insert(row, c, require('fey.files.elements.table.cell'):new({ row_idx = row_idx, col_idx = c }))
  end
  tbl:reformat()
end

function TableOps.insert_col_after()
  local tbl, _, c = get_ctx()
  if not tbl then return end

  for row_idx, row in ipairs(tbl.logical_grid) do
    table.insert(row, c + 1, require('fey.files.elements.table.cell'):new({ row_idx = row_idx, col_idx = c + 1 }))
  end
  tbl:reformat()
end

function TableOps.delete_col()
  local tbl, _, c = get_ctx()
  if not tbl then return end

  for _, row in ipairs(tbl.logical_grid) do
    table.remove(row, c)
  end
  tbl:reformat()
end

function TableOps.move_col_left()
  local tbl, _, c = get_ctx()
  if not tbl then return end

  if c > 1 then
    for _, row in ipairs(tbl.logical_grid) do
      row[c], row[c - 1] = row[c - 1], row[c]
    end
    tbl:reformat()
  end
end

function TableOps.move_col_right()
  local tbl, _, c = get_ctx()
  if not tbl then return end

  if c < #tbl.logical_grid[1] then
    for _, row in ipairs(tbl.logical_grid) do
      row[c], row[c + 1] = row[c + 1], row[c]
    end
    tbl:reformat()
  end
end

function TableOps.move_cell_up()
  local tbl, r, c = get_ctx()
  if not tbl then return end

  if r > 1 then
    tbl.logical_grid[r][c], tbl.logical_grid[r - 1][c] = tbl.logical_grid[r - 1][c], tbl.logical_grid[r][c]
    tbl:reformat()
  end
end

function TableOps.move_cell_down()
  local tbl, r, c = get_ctx()
  if not tbl then return end

  if r < #tbl.logical_grid then
    tbl.logical_grid[r][c], tbl.logical_grid[r + 1][c] = tbl.logical_grid[r + 1][c], tbl.logical_grid[r][c]
    tbl:reformat()
  end
end

function TableOps.move_cell_left()
  local tbl, r, c = get_ctx()
  if not tbl then return end

  if c > 1 then
    tbl.logical_grid[r][c], tbl.logical_grid[r][c - 1] = tbl.logical_grid[r][c - 1], tbl.logical_grid[r][c]
    tbl:reformat()
  end
end

function TableOps.move_cell_right()
  local tbl, r, c = get_ctx()
  if not tbl then return end

  if c < #tbl.logical_grid[1] then
    tbl.logical_grid[r][c], tbl.logical_grid[r][c + 1] = tbl.logical_grid[r][c + 1], tbl.logical_grid[r][c]
    tbl:reformat()
  end
end

function TableOps.merge_cell_right()
  local tbl, r, c = get_ctx()
  if not tbl then return end

  local cell = tbl.logical_grid[r][c]
  local target = tbl.logical_grid[r][c + cell.colspan]
  if target then
    cell.colspan = cell.colspan + target.colspan
    for i = 1, target.colspan do
      tbl.logical_grid[r][c + cell.colspan - i] = cell
    end
    tbl:reformat()
  end
end

function TableOps.merge_cell_down()
  local tbl, r, c = get_ctx()
  if not tbl then return end

  local cell = tbl.logical_grid[r][c]
  local target = tbl.logical_grid[r + cell.rowspan] and tbl.logical_grid[r + cell.rowspan][c]
  if target then
    cell.rowspan = cell.rowspan + target.rowspan
    for i = 1, target.rowspan do
      tbl.logical_grid[r + cell.rowspan - i][c] = cell
    end
    tbl:reformat()
  end
end

function TableOps.unmerge_cells()
  local tbl, r, c = get_ctx()
  if not tbl then return end

  local cell = tbl.logical_grid[r][c]
  -- Replace all references in the logical grid that point to this spanned cell with distinct 1x1 cells
  for row_idx = r, r + cell.rowspan - 1 do
    for col_idx = c, c + cell.colspan - 1 do
      if row_idx ~= r or col_idx ~= c then
        tbl.logical_grid[row_idx][col_idx] =
          require('fey.files.elements.table.cell'):new({ row_idx = row_idx, col_idx = col_idx })
      end
    end
  end
  cell.rowspan, cell.colspan = 1, 1
  tbl:reformat()
end

return TableOps
