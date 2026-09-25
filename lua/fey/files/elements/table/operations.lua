local TableRow = require('fey.files.elements.table.row')
local TableCell = require('fey.files.elements.table.cell')
local Table = require('fey.files.elements.table')

local TableOps = {}

-- Helper to safely get the table and logical cell position at cursor
local function get_ctx()
  local tbl = Table.from_current_node()
  if not tbl then return nil, 1, 1 end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local cursor_line = cursor[1]
  local cursor_col = cursor[2]

  local logical_row_idx = 1
  local r, c = 1, 1
  local current_phys_rows = 0
  local found = false

  -- Map the physical line location of the cursor back to the logical row and col indexes
  for child in tbl.node:iter_children() do
    local c_type = child:type()
    -- local sr, sc, er, cec = child:range()
    local sr = child:range()
    local line_num = sr + 1

    if c_type == 'row' then
      current_phys_rows = current_phys_rows + 1
      if line_num == cursor_line then
        r = logical_row_idx
        local cells = child:field('cell')
        local phys_col = 1
        for _, cell_node in ipairs(cells) do
          -- local csr, csc, cer, cc = cell_node:range()
          local _, csc, _, cc = cell_node:range()
          if cursor_col >= csc and cursor_col <= cc then
            if tbl.rows[r] and tbl.rows[r].cells[phys_col] then
              c = tbl.rows[r].cells[phys_col].col_idx
            else
              c = phys_col
            end
            found = true
            break
          end
          phys_col = phys_col + 1
        end
      end
    elseif c_type == 'hr' or c_type == 'cbo' or c_type == 'cbi' then
      if current_phys_rows > 0 then
        logical_row_idx = logical_row_idx + 1
        current_phys_rows = 0
      end
    end
    if found then break end
  end

  return tbl, r, c
end

-- Rebuilds boundary spans/vmerges in logical_grid based on tbl.rows
local function sync_boundaries(tbl)
  local old_grid = tbl.logical_grid
  local new_grid = {}
  local row_idx = 1

  -- Reconstruct grid sequence while preserving manual 'hr' lines
  for _, item in ipairs(old_grid) do
    if item.type == 'hr' or item.type == 'cbo' or item.type == 'cbi' then
      table.insert(new_grid, item)
    else
      local row = tbl.rows[row_idx]
      if row then
        table.insert(new_grid, row)
        row_idx = row_idx + 1
      end
    end
  end

  -- Add generic bounds for newly inserted rows at the end
  while row_idx <= #tbl.rows do
    table.insert(new_grid, { type = 'cbo', spans = {} })
    table.insert(new_grid, tbl.rows[row_idx])
    row_idx = row_idx + 1
  end

  -- Update spans based on the structural constraints of the immediately following row
  for i, item in ipairs(new_grid) do
    if item.type == 'hr' or item.type == 'cbo' or item.type == 'cbi' then
      local next_row = nil
      for j = i + 1, #new_grid do
        if not new_grid[j].type then
          next_row = new_grid[j]
          break
        end
      end

      if next_row then
        local spans = {}
        local col = 1
        while col <= tbl.col_count do
          local cell = nil
          for _, cl in ipairs(next_row.cells) do
            if cl.col_idx == col then
              cell = cl
              break
            end
          end
          if cell then
            -- vmerge is true if the cell is a continuation from above (rowspan == 0)
            table.insert(spans, { span = cell.colspan, vmerge = (cell.rowspan == 0) })
            col = col + cell.colspan
          else
            table.insert(spans, { span = 1, vmerge = false })
            col = col + 1
          end
        end
        item.spans = spans
      else
        -- Bottom boundary mirrors the last row without vmerges
        local prev_row = tbl.rows[#tbl.rows]
        if prev_row then
          local spans = {}
          local col = 1
          while col <= tbl.col_count do
            local cell = nil
            for _, cl in ipairs(prev_row.cells) do
              if cl.col_idx == col then
                cell = cl
                break
              end
            end
            if cell then
              table.insert(spans, { span = cell.colspan, vmerge = false })
              col = col + cell.colspan
            else
              table.insert(spans, { span = 1, vmerge = false })
              col = col + 1
            end
          end
          item.spans = spans
        end
      end
    end
  end

  tbl.logical_grid = new_grid
end

function TableOps.reformat()
  local tbl = get_ctx()
  if tbl then tbl:reformat() end
end

function TableOps.insert_row_after()
  local tbl, r, _ = get_ctx()
  if not tbl then return end

  local new_row = TableRow:new({ table = tbl, line = r + 1 })
  for i = 1, tbl.col_count do
    new_row:add_cell(TableCell:new({ row_idx = r + 1, col_idx = i }))
  end

  for i = r + 1, #tbl.rows do
    tbl.rows[i].line = i + 1
    for _, cl in ipairs(tbl.rows[i].cells) do
      cl.row_idx = cl.row_idx + 1
    end
  end
  table.insert(tbl.rows, r + 1, new_row)

  sync_boundaries(tbl)
  tbl:reformat()
end

function TableOps.insert_row_before()
  local tbl, r, _ = get_ctx()
  if not tbl then return end

  local new_row = TableRow:new({ table = tbl, line = r })
  for i = 1, tbl.col_count do
    new_row:add_cell(TableCell:new({ row_idx = r, col_idx = i }))
  end

  for i = r, #tbl.rows do
    tbl.rows[i].line = i + 1
    for _, cl in ipairs(tbl.rows[i].cells) do
      cl.row_idx = cl.row_idx + 1
    end
  end
  table.insert(tbl.rows, r, new_row)

  sync_boundaries(tbl)
  tbl:reformat()
end

function TableOps.delete_row()
  local tbl, r, _ = get_ctx()
  if not tbl or #tbl.rows <= 1 then return end

  table.remove(tbl.rows, r)
  for i = r, #tbl.rows do
    tbl.rows[i].line = i
    for _, cl in ipairs(tbl.rows[i].cells) do
      cl.row_idx = cl.row_idx - 1
    end
  end

  sync_boundaries(tbl)
  tbl:reformat()
end

function TableOps.insert_col_before()
  local tbl, _, c = get_ctx()
  if not tbl then return end

  tbl.col_count = tbl.col_count + 1

  for r_idx, row in ipairs(tbl.rows) do
    local inserted = false
    -- Shift columns right or expand cells that span across the insertion point
    for _, cell in ipairs(row.cells) do
      if cell.col_idx < c and cell.col_idx + cell.colspan > c then
        cell.colspan = cell.colspan + 1
        inserted = true
      elseif cell.col_idx >= c then
        cell.col_idx = cell.col_idx + 1
      end
    end

    -- If no cell spanned across this gap, insert a fresh 1x1 cell
    if not inserted then
      local idx = 1
      while idx <= #row.cells and row.cells[idx].col_idx < c do
        idx = idx + 1
      end
      local new_cell = TableCell:new({ row_idx = r_idx, col_idx = c, colspan = 1, rowspan = 1, lines = {} })
      table.insert(row.cells, idx, new_cell)
    end
  end

  sync_boundaries(tbl)
  tbl:reformat()
end

function TableOps.insert_col_after()
  local tbl, r, c = get_ctx()
  if not tbl then return end

  -- Determine target column based on the current cell's colspan
  local target_c = c + 1
  for _, cl in ipairs(tbl.rows[r].cells) do
    if cl.col_idx == c then
      target_c = cl.col_idx + cl.colspan
      break
    end
  end

  tbl.col_count = tbl.col_count + 1

  for r_idx, row in ipairs(tbl.rows) do
    local inserted = false
    for _, cell in ipairs(row.cells) do
      if cell.col_idx < target_c and cell.col_idx + cell.colspan > target_c then
        cell.colspan = cell.colspan + 1
        inserted = true
      elseif cell.col_idx >= target_c then
        cell.col_idx = cell.col_idx + 1
      end
    end

    if not inserted then
      local idx = 1
      while idx <= #row.cells and row.cells[idx].col_idx < target_c do
        idx = idx + 1
      end
      local new_cell = TableCell:new({ row_idx = r_idx, col_idx = target_c, colspan = 1, rowspan = 1, lines = {} })
      table.insert(row.cells, idx, new_cell)
    end
  end

  sync_boundaries(tbl)
  tbl:reformat()
end

function TableOps.move_col_left()
  local tbl, _, c = get_ctx()
  if not tbl or c <= 1 then return end

  -- Validate that no cells cross the boundary or have colspans in the involved columns
  for _, row in ipairs(tbl.rows) do
    for _, cell in ipairs(row.cells) do
      if (cell.col_idx == c or cell.col_idx == c - 1) and cell.colspan > 1 then
        vim.notify('Fey: Cannot move columns containing multi-column cells. Unmerge first.', vim.log.levels.ERROR)
        return
      elseif cell.col_idx < c - 1 and cell.col_idx + cell.colspan > c - 1 then
        vim.notify('Fey: Cannot move columns spanned by multi-column cells.', vim.log.levels.ERROR)
        return
      end
    end
  end

  for _, row in ipairs(tbl.rows) do
    local idx_c, idx_prev
    for i, cell in ipairs(row.cells) do
      if cell.col_idx == c then
        idx_c = i
      elseif cell.col_idx == c - 1 then
        idx_prev = i
      end
    end
    if idx_c and idx_prev then
      row.cells[idx_c], row.cells[idx_prev] = row.cells[idx_prev], row.cells[idx_c]
      row.cells[idx_c].col_idx = c
      row.cells[idx_prev].col_idx = c - 1
    end
  end

  sync_boundaries(tbl)
  tbl:reformat()
end

function TableOps.delete_col()
  local tbl, _, c = get_ctx()
  if not tbl then return end

  if tbl.col_count <= 1 then
    vim.notify('Fey: Cannot delete the last remaining column.', vim.log.levels.WARN)
    return
  end

  tbl.col_count = tbl.col_count - 1

  for _, row in ipairs(tbl.rows) do
    local remove_idx = nil

    for i, cell in ipairs(row.cells) do
      -- Check if the deleted column falls inside this cell's horizontal span
      if cell.col_idx <= c and (cell.col_idx + cell.colspan - 1) >= c then
        if cell.colspan > 1 then
          cell.colspan = cell.colspan - 1
          -- cell.col_idx remains the same since the left boundary didn't move past it
        else
          remove_idx = i
        end
      elseif cell.col_idx > c then
        -- Cells completely to the right of the deleted column shift left
        cell.col_idx = cell.col_idx - 1
      end
    end

    if remove_idx then table.remove(row.cells, remove_idx) end
  end

  sync_boundaries(tbl)
  tbl:reformat()
end

function TableOps.move_col_right()
  local tbl, _, c = get_ctx()
  if not tbl or c >= tbl.col_count then return end

  -- Validate that no cells cross the boundary or have colspans in the involved columns
  for _, row in ipairs(tbl.rows) do
    for _, cell in ipairs(row.cells) do
      if (cell.col_idx == c or cell.col_idx == c + 1) and cell.colspan > 1 then
        vim.notify('Fey: Cannot move columns containing multi-column cells. Unmerge first.', vim.log.levels.ERROR)
        return
      elseif cell.col_idx < c and cell.col_idx + cell.colspan > c then
        vim.notify('Fey: Cannot move columns spanned by multi-column cells.', vim.log.levels.ERROR)
        return
      end
    end
  end

  for _, row in ipairs(tbl.rows) do
    local idx_c, idx_next
    for i, cell in ipairs(row.cells) do
      if cell.col_idx == c then
        idx_c = i
      elseif cell.col_idx == c + 1 then
        idx_next = i
      end
    end
    if idx_c and idx_next then
      row.cells[idx_c], row.cells[idx_next] = row.cells[idx_next], row.cells[idx_c]
      row.cells[idx_c].col_idx = c
      row.cells[idx_next].col_idx = c + 1
    end
  end

  sync_boundaries(tbl)
  tbl:reformat()
end

function TableOps.move_row_up()
  local tbl, r, _ = get_ctx()
  if not tbl or r <= 1 then return end

  tbl.rows[r], tbl.rows[r - 1] = tbl.rows[r - 1], tbl.rows[r]
  tbl.rows[r].line = r
  tbl.rows[r - 1].line = r - 1
  for _, cell in ipairs(tbl.rows[r].cells) do
    cell.row_idx = r
  end
  for _, cell in ipairs(tbl.rows[r - 1].cells) do
    cell.row_idx = r - 1
  end

  sync_boundaries(tbl)
  tbl:reformat()
end

function TableOps.move_row_down()
  local tbl, r, _ = get_ctx()
  if not tbl or r >= #tbl.rows then return end

  tbl.rows[r], tbl.rows[r + 1] = tbl.rows[r + 1], tbl.rows[r]
  tbl.rows[r].line = r
  tbl.rows[r + 1].line = r + 1
  for _, cell in ipairs(tbl.rows[r].cells) do
    cell.row_idx = r
  end
  for _, cell in ipairs(tbl.rows[r + 1].cells) do
    cell.row_idx = r + 1
  end

  sync_boundaries(tbl)
  tbl:reformat()
end

function TableOps.move_cell_left()
  local tbl, r, c = get_ctx()
  if not tbl then return end
  local row = tbl.rows[r]

  local idx, cell = nil, nil
  for i, cl in ipairs(row.cells) do
    if cl.col_idx == c then
      idx = i
      cell = cl
      break
    end
  end
  if not cell or idx <= 1 then return end

  local prev_cell = row.cells[idx - 1]
  if cell.rowspan ~= prev_cell.rowspan then
    vim.notify('Fey: Cannot swap logical cells with different rowspans.', vim.log.levels.ERROR)
    return
  end

  row.cells[idx], row.cells[idx - 1] = row.cells[idx - 1], row.cells[idx]
  local temp_col = prev_cell.col_idx
  prev_cell.col_idx = temp_col + cell.colspan
  cell.col_idx = temp_col

  sync_boundaries(tbl)
  tbl:reformat()
end

function TableOps.move_cell_right()
  local tbl, r, c = get_ctx()
  if not tbl then return end
  local row = tbl.rows[r]

  local idx, cell = nil, nil
  for i, cl in ipairs(row.cells) do
    if cl.col_idx == c then
      idx = i
      cell = cl
      break
    end
  end
  if not cell or idx >= #row.cells then return end

  local next_cell = row.cells[idx + 1]
  if cell.rowspan ~= next_cell.rowspan then
    vim.notify('Fey: Cannot swap logical cells with different rowspans.', vim.log.levels.ERROR)
    return
  end

  row.cells[idx], row.cells[idx + 1] = row.cells[idx + 1], row.cells[idx]
  local temp_col = cell.col_idx
  cell.col_idx = temp_col + next_cell.colspan
  next_cell.col_idx = temp_col

  sync_boundaries(tbl)
  tbl:reformat()
end

function TableOps.move_cell_up()
  local tbl, r, c = get_ctx()
  if not tbl or r <= 1 then return end

  local cell, target_cell, cell_idx, target_idx
  for i, cl in ipairs(tbl.rows[r].cells) do
    if cl.col_idx == c then
      cell = cl
      cell_idx = i
      break
    end
  end
  for i, cl in ipairs(tbl.rows[r - 1].cells) do
    if cl.col_idx == c then
      target_cell = cl
      target_idx = i
      break
    end
  end

  if not cell or not target_cell then return end
  if cell.colspan ~= target_cell.colspan then
    vim.notify('Fey: Cannot swap logical cells with different colspans.', vim.log.levels.ERROR)
    return
  end

  tbl.rows[r].cells[cell_idx] = target_cell
  tbl.rows[r - 1].cells[target_idx] = cell
  cell.row_idx = r - 1
  target_cell.row_idx = r

  sync_boundaries(tbl)
  tbl:reformat()
end

function TableOps.move_cell_down()
  local tbl, r, c = get_ctx()
  if not tbl or r >= #tbl.rows then return end

  local cell, target_cell, cell_idx, target_idx
  for i, cl in ipairs(tbl.rows[r].cells) do
    if cl.col_idx == c then
      cell = cl
      cell_idx = i
      break
    end
  end
  for i, cl in ipairs(tbl.rows[r + 1].cells) do
    if cl.col_idx == c then
      target_cell = cl
      target_idx = i
      break
    end
  end

  if not cell or not target_cell then return end
  if cell.colspan ~= target_cell.colspan then
    vim.notify('Fey: Cannot swap logical cells with different colspans.', vim.log.levels.ERROR)
    return
  end

  tbl.rows[r].cells[cell_idx] = target_cell
  tbl.rows[r + 1].cells[target_idx] = cell
  cell.row_idx = r + 1
  target_cell.row_idx = r

  sync_boundaries(tbl)
  tbl:reformat()
end

function TableOps.merge_cell_right()
  local tbl, r, c = get_ctx()
  if not tbl then return end
  local row = tbl.rows[r]

  local idx, cell = nil, nil
  for i, cl in ipairs(row.cells) do
    if cl.col_idx == c then
      idx = i
      cell = cl
      break
    end
  end
  if not cell or idx == #row.cells then return end

  local target = row.cells[idx + 1]
  if target.rowspan ~= cell.rowspan then
    vim.notify('Fey: Cannot merge logical cells with different cross-axis rowspans.', vim.log.levels.ERROR)
    return
  end

  for _, ln in ipairs(target.lines) do
    table.insert(cell.lines, ln)
  end
  cell.colspan = cell.colspan + target.colspan
  cell:update_display_len()

  table.remove(row.cells, idx + 1)

  -- Clear out subsequent vmerged placeholders if rowspan spans down
  if cell.rowspan > 1 then
    for step = 1, cell.rowspan - 1 do
      local next_row = tbl.rows[r + step]
      if next_row then
        for ni, nc in ipairs(next_row.cells) do
          if nc.col_idx == target.col_idx then
            table.remove(next_row.cells, ni)
            break
          end
        end
      end
    end
  end

  sync_boundaries(tbl)
  tbl:reformat()
end

function TableOps.merge_cell_down()
  local tbl, r, c = get_ctx()
  if not tbl or r == #tbl.rows then return end

  local cell, target = nil, nil
  for _, cl in ipairs(tbl.rows[r].cells) do
    if cl.col_idx == c then
      cell = cl
      break
    end
  end
  for _, cl in ipairs(tbl.rows[r + 1].cells) do
    if cl.col_idx == c then
      target = cl
      break
    end
  end

  if not cell or not target then return end
  if target.colspan ~= cell.colspan then
    vim.notify('Fey: Cannot merge logical cells with different cross-axis colspans.', vim.log.levels.ERROR)
    return
  end

  for _, ln in ipairs(target.lines) do
    table.insert(cell.lines, ln)
  end
  cell.rowspan = cell.rowspan + target.rowspan
  cell:update_display_len()

  -- Transform target into a placeholder cell directly to avoid layout shift
  target.rowspan = 0
  target.lines = {}
  target:update_display_len()

  sync_boundaries(tbl)
  tbl:reformat()
end

function TableOps.unmerge_cells()
  local tbl, r, c = get_ctx()
  if not tbl then return end
  local row = tbl.rows[r]

  local idx, cell = nil, nil
  for i, cl in ipairs(row.cells) do
    if cl.col_idx == c then
      idx = i
      cell = cl
      break
    end
  end
  if not cell or (cell.colspan == 1 and cell.rowspan == 1) then return end

  local orig_colspan = cell.colspan
  local orig_rowspan = cell.rowspan
  cell.colspan = 1
  cell.rowspan = 1

  -- Restore horizontal cells
  for extra_c = 1, orig_colspan - 1 do
    local new_c = c + extra_c
    local new_cell = TableCell:new({ row_idx = r, col_idx = new_c, colspan = 1, rowspan = 1, lines = {} })
    table.insert(row.cells, idx + extra_c, new_cell)
  end

  -- Restore vertical placeholders as standard 1x1 cells
  for extra_r = 1, orig_rowspan - 1 do
    local next_row = tbl.rows[r + extra_r]
    if next_row then
      local insert_idx = 1
      for ni, nc in ipairs(next_row.cells) do
        if nc.col_idx == c then
          insert_idx = ni
          break
        end
      end

      if next_row.cells[insert_idx] and next_row.cells[insert_idx].col_idx == c and next_row.cells[insert_idx].rowspan == 0 then
        table.remove(next_row.cells, insert_idx)
      end

      for extra_c = 0, orig_colspan - 1 do
        local new_c = c + extra_c
        local new_cell = TableCell:new({ row_idx = r + extra_r, col_idx = new_c, colspan = 1, rowspan = 1, lines = {} })
        table.insert(next_row.cells, insert_idx + extra_c, new_cell)
      end
    end
  end

  sync_boundaries(tbl)
  tbl:reformat()
end

return TableOps
