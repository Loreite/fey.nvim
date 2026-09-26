local TableRow = require('fey.files.elements.table.row')
local TableCell = require('fey.files.elements.table.cell')
local Table = require('fey.files.elements.table')
local ts_utils = require('fey.utils.treesitter')

local TableOps = {}

-- Helper to safely get the table and logical cell position at cursor
function TableOps.get_ctx()
  local tbl = Table.from_current_node()
  if not tbl then return nil, 1, 1 end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local r, c = 1, 1

  -- Fetch closest valid cell to exact cursor position
  local cell_node = ts_utils.get_node_at_cursor(cursor)
  if cell_node and cell_node:type() ~= 'cell' then cell_node = ts_utils.closest_node(cell_node, 'cell') end

  if cell_node then
    local s_row, s_col = cell_node:start()
    local mapped = tbl.node_map[('%d,%d'):format(s_row, s_col)]
    if mapped then
      r, c = mapped.r, mapped.c
    end
  end

  return tbl, r, c
end

-- Rebuilds boundary spans/vmerges dynamically based on table content
local function sync_boundaries(tbl)
  local old_grid = tbl.logical_grid
  local boundary_before_row = {}
  local last_boundary = nil

  -- Catalog existing manual boundaries by mapping them to their specific row objects
  for _, item in ipairs(old_grid) do
    if item.type then
      last_boundary = item.type
    else
      boundary_before_row[item] = last_boundary
      last_boundary = nil
    end
  end
  local trailing_boundary = last_boundary

  local new_grid = {}
  local in_multi = false

  for i, row in ipairs(tbl.rows) do
    local needed_boundary = nil
    local needs_cbi = false
    local has_colspan = false
    local has_multiline = false

    for _, cell in ipairs(row.cells) do
      if cell.rowspan == 0 then needs_cbi = true end
      if cell.colspan > 1 then has_colspan = true end
      if #cell.lines > 1 then has_multiline = true end
    end

    local prev_has_multiline = false
    if i > 1 then
      for _, cell in ipairs(tbl.rows[i - 1].cells) do
        if #cell.lines > 1 then prev_has_multiline = true end
      end
    end

    if needs_cbi then
      needed_boundary = 'cbi'
      in_multi = true
    elseif has_colspan or has_multiline or prev_has_multiline then
      needed_boundary = 'cbo'
      in_multi = true
    else
      if in_multi then
        needed_boundary = 'cbo'
        in_multi = false
      end
    end

    -- Preserve manual HRs over automatic bounds using the object reference
    local existing = boundary_before_row[row]
    if existing == 'hr' then needed_boundary = needs_cbi and 'cbi' or 'hr' end

    if i > 1 and needed_boundary then
      table.insert(new_grid, { type = needed_boundary, spans = {} })
    elseif i == 1 and existing == 'hr' then
      table.insert(new_grid, { type = 'hr', spans = {} })
    end

    table.insert(new_grid, row)
  end

  -- Trailing cap
  if in_multi or trailing_boundary == 'hr' then
    table.insert(new_grid, { type = trailing_boundary == 'hr' and 'hr' or 'cbo', spans = {} })
  end

  -- Update visual drawing spans for the active boundaries
  for idx, item in ipairs(new_grid) do
    if item.type then
      local next_row = nil
      for j = idx + 1, #new_grid do
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
            table.insert(spans, { span = cell.colspan, vmerge = (cell.rowspan == 0) })
            col = col + cell.colspan
          else
            table.insert(spans, { span = 1, vmerge = false })
            col = col + 1
          end
        end
        item.spans = spans
      else
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

-- HELPER: Get the multi-column span block spanning consecutive spanned cells
local function get_col_block(tbl, c)
  local start_c, end_c = c, c
  local changed = true
  while changed do
    changed = false
    for _, row in ipairs(tbl.rows) do
      for _, cell in ipairs(row.cells) do
        if cell.colspan > 1 then
          local c_start, c_end = cell.col_idx, cell.col_idx + cell.colspan - 1
          if not (c_end < start_c or c_start > end_c) then
            if c_start < start_c then
              start_c = c_start
              changed = true
            end
            if c_end > end_c then
              end_c = c_end
              changed = true
            end
          end
        end
      end
    end
  end
  return start_c, end_c
end

-- HELPER: Get the multi-row span block spanning consecutive vmerges
local function get_row_block(tbl, r)
  local start_r, end_r = r, r
  local changed = true
  while changed do
    changed = false
    for i, row in ipairs(tbl.rows) do
      for _, cell in ipairs(row.cells) do
        if cell.rowspan > 1 then
          local c_start, c_end = i, i + cell.rowspan - 1
          if not (c_end < start_r or c_start > end_r) then
            if c_start < start_r then
              start_r = c_start
              changed = true
            end
            if c_end > end_r then
              end_r = c_end
              changed = true
            end
          end
        end
      end
    end
  end
  return start_r, end_r
end

-- HELPER: Grabs the top root of a vertical cell group regardless of cursor placement
local function get_vmerge_block(tbl, r, c)
  local start_r = r
  local cell = nil
  while start_r >= 1 do
    for _, cl in ipairs(tbl.rows[start_r].cells) do
      if cl.col_idx == c then
        cell = cl
        break
      end
    end
    if cell and cell.rowspan > 0 then break end
    start_r = start_r - 1
  end
  if not cell or cell.rowspan == 0 then return nil end
  return start_r, cell.rowspan, cell
end

-- HELPER: Shifts full blocks of cells vertically
local function swap_vmerge_blocks(tbl, c, r1, span1, r2, span2)
  local extracted = {}
  for i = r1, r2 + span2 - 1 do
    local row = tbl.rows[i]
    local found_idx, cell
    for j, cl in ipairs(row.cells) do
      if cl.col_idx == c then
        found_idx = j
        cell = cl
        break
      end
    end
    table.remove(row.cells, found_idx)
    table.insert(extracted, cell)
  end

  local blockA, blockB = {}, {}
  for i = 1, span1 do
    table.insert(blockA, extracted[i])
  end
  for i = 1, span2 do
    table.insert(blockB, extracted[span1 + i])
  end

  for i, cell in ipairs(blockB) do
    cell.row_idx = r1 + i - 1
  end
  for i, cell in ipairs(blockA) do
    cell.row_idx = r1 + span2 + i - 1
  end

  local new_seq = {}
  for _, cl in ipairs(blockB) do
    table.insert(new_seq, cl)
  end
  for _, cl in ipairs(blockA) do
    table.insert(new_seq, cl)
  end

  for i = r1, r2 + span2 - 1 do
    local row = tbl.rows[i]
    local ins_cl = new_seq[i - r1 + 1]
    local ins_idx = 1
    while ins_idx <= #row.cells and row.cells[ins_idx].col_idx < c do
      ins_idx = ins_idx + 1
    end
    table.insert(row.cells, ins_idx, ins_cl)
  end
end

function TableOps.reformat()
  local tbl = TableOps.get_ctx()
  if tbl then tbl:reformat() end
end

function TableOps.insert_row_after()
  local tbl, r, _ = TableOps.get_ctx()
  if not tbl then return end

  local new_row = TableRow:new({ table = tbl, line = r + 1 })
  for i = 1, tbl.col_count do
    new_row:add_cell(TableCell:new({ row_idx = r + 1, col_idx = i }))
  end

  table.insert(tbl.rows, r + 1, new_row)
  for i = r + 2, #tbl.rows do
    tbl.rows[i].line = i
    for _, cl in ipairs(tbl.rows[i].cells) do
      cl.row_idx = i
    end
  end

  sync_boundaries(tbl)
  tbl:reformat()
end

function TableOps.insert_row_before()
  local tbl, r, _ = TableOps.get_ctx()
  if not tbl then return end

  local new_row = TableRow:new({ table = tbl, line = r })
  for i = 1, tbl.col_count do
    new_row:add_cell(TableCell:new({ row_idx = r, col_idx = i }))
  end

  table.insert(tbl.rows, r, new_row)
  for i = r + 1, #tbl.rows do
    tbl.rows[i].line = i
    for _, cl in ipairs(tbl.rows[i].cells) do
      cl.row_idx = i
    end
  end

  sync_boundaries(tbl)
  tbl:reformat()
end

function TableOps.delete_row()
  local tbl, r, _ = TableOps.get_ctx()
  if not tbl or #tbl.rows <= 1 then return end

  table.remove(tbl.rows, r)
  for i = r, #tbl.rows do
    tbl.rows[i].line = i
    for _, cl in ipairs(tbl.rows[i].cells) do
      cl.row_idx = i
    end
  end

  sync_boundaries(tbl)
  tbl:reformat()
end

function TableOps.insert_col_before()
  local tbl, _, c = TableOps.get_ctx()
  if not tbl then return end

  tbl.col_count = tbl.col_count + 1

  for r_idx, row in ipairs(tbl.rows) do
    local inserted = false
    for _, cell in ipairs(row.cells) do
      if cell.col_idx < c and cell.col_idx + cell.colspan > c then
        cell.colspan = cell.colspan + 1
        inserted = true
      elseif cell.col_idx >= c then
        cell.col_idx = cell.col_idx + 1
      end
    end

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
  local tbl, r, c = TableOps.get_ctx()
  if not tbl then return end

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
  local tbl, _, c = TableOps.get_ctx()
  if not tbl or c <= 1 then return end

  local c2_start, c2_end = get_col_block(tbl, c)
  if c2_start <= 1 then return end

  local c1_start, c1_end = get_col_block(tbl, c2_start - 1)
  local w1, w2 = c1_end - c1_start + 1, c2_end - c2_start + 1

  for _, row in ipairs(tbl.rows) do
    for _, cell in ipairs(row.cells) do
      if cell.col_idx >= c1_start and cell.col_idx <= c1_end then
        cell.col_idx = cell.col_idx + w2
      elseif cell.col_idx >= c2_start and cell.col_idx <= c2_end then
        cell.col_idx = cell.col_idx - w1
      end
    end
    table.sort(row.cells, function(a, b) return a.col_idx < b.col_idx end)
  end

  sync_boundaries(tbl)
  tbl:reformat()
end

function TableOps.delete_col()
  local tbl, _, c = TableOps.get_ctx()
  if not tbl then return end
  if tbl.col_count <= 1 then
    vim.notify('Fey: Cannot delete the last remaining column.', vim.log.levels.WARN)
    return
  end

  tbl.col_count = tbl.col_count - 1

  for _, row in ipairs(tbl.rows) do
    local remove_idx = nil
    for i, cell in ipairs(row.cells) do
      if cell.col_idx <= c and (cell.col_idx + cell.colspan - 1) >= c then
        if cell.colspan > 1 then
          cell.colspan = cell.colspan - 1
        else
          remove_idx = i
        end
      elseif cell.col_idx > c then
        cell.col_idx = cell.col_idx - 1
      end
    end
    if remove_idx then table.remove(row.cells, remove_idx) end
  end

  sync_boundaries(tbl)
  tbl:reformat()
end

function TableOps.move_col_right()
  local tbl, _, c = TableOps.get_ctx()
  if not tbl or c >= tbl.col_count then return end

  local c1_start, c1_end = get_col_block(tbl, c)
  if c1_end >= tbl.col_count then return end

  local c2_start, c2_end = get_col_block(tbl, c1_end + 1)
  local w1, w2 = c1_end - c1_start + 1, c2_end - c2_start + 1

  for _, row in ipairs(tbl.rows) do
    for _, cell in ipairs(row.cells) do
      if cell.col_idx >= c1_start and cell.col_idx <= c1_end then
        cell.col_idx = cell.col_idx + w2
      elseif cell.col_idx >= c2_start and cell.col_idx <= c2_end then
        cell.col_idx = cell.col_idx - w1
      end
    end
    table.sort(row.cells, function(a, b) return a.col_idx < b.col_idx end)
  end

  sync_boundaries(tbl)
  tbl:reformat()
end

function TableOps.move_row_up()
  local tbl, r, _ = TableOps.get_ctx()
  if not tbl or r <= 1 then return end

  local r2_start, r2_end = get_row_block(tbl, r)
  if r2_start <= 1 then return end

  local r1_start, r1_end = get_row_block(tbl, r2_start - 1)

  local new_rows = {}
  for i = 1, r1_start - 1 do
    table.insert(new_rows, tbl.rows[i])
  end
  for i = r2_start, r2_end do
    table.insert(new_rows, tbl.rows[i])
  end
  for i = r1_start, r1_end do
    table.insert(new_rows, tbl.rows[i])
  end
  for i = r2_end + 1, #tbl.rows do
    table.insert(new_rows, tbl.rows[i])
  end

  tbl.rows = new_rows
  for i, row in ipairs(tbl.rows) do
    row.line = i
    for _, cell in ipairs(row.cells) do
      cell.row_idx = i
    end
  end

  sync_boundaries(tbl)
  tbl:reformat()
end

function TableOps.move_row_down()
  local tbl, r, _ = TableOps.get_ctx()
  if not tbl or r >= #tbl.rows then return end

  local r1_start, r1_end = get_row_block(tbl, r)
  if r1_end >= #tbl.rows then return end

  local r2_start, r2_end = get_row_block(tbl, r1_end + 1)

  local new_rows = {}
  for i = 1, r1_start - 1 do
    table.insert(new_rows, tbl.rows[i])
  end
  for i = r2_start, r2_end do
    table.insert(new_rows, tbl.rows[i])
  end
  for i = r1_start, r1_end do
    table.insert(new_rows, tbl.rows[i])
  end
  for i = r2_end + 1, #tbl.rows do
    table.insert(new_rows, tbl.rows[i])
  end

  tbl.rows = new_rows
  for i, row in ipairs(tbl.rows) do
    row.line = i
    for _, cell in ipairs(row.cells) do
      cell.row_idx = i
    end
  end

  sync_boundaries(tbl)
  tbl:reformat()
end

function TableOps.move_cell_left()
  local tbl, r, c = TableOps.get_ctx()
  if not tbl then return end

  local r_start, span, cell = get_vmerge_block(tbl, r, c)
  if not r_start then return end

  local root_row = tbl.rows[r_start]
  local idx
  for i, cl in ipairs(root_row.cells) do
    if cl.col_idx == c then
      idx = i
      break
    end
  end
  if not idx or idx <= 1 then return end

  local prev_cell = root_row.cells[idx - 1]
  if cell.rowspan ~= prev_cell.rowspan then
    vim.notify('Fey: Cannot swap logical cells with different rowspans.', vim.log.levels.ERROR)
    return
  end

  local new_c1_col = prev_cell.col_idx + cell.colspan
  local new_c2_col = prev_cell.col_idx

  for i = 0, span - 1 do
    local cur_r = r_start + i
    local cur_row = tbl.rows[cur_r]
    local c1, c2
    for _, cl in ipairs(cur_row.cells) do
      if cl.col_idx == prev_cell.col_idx then c1 = cl end
      if cl.col_idx == cell.col_idx then c2 = cl end
    end
    if c1 and c2 then
      c1.col_idx = new_c1_col
      c2.col_idx = new_c2_col
    end
    table.sort(cur_row.cells, function(a, b) return a.col_idx < b.col_idx end)
  end

  sync_boundaries(tbl)
  tbl:reformat()
end

function TableOps.move_cell_right()
  local tbl, r, c = TableOps.get_ctx()
  if not tbl then return end

  local r_start, span, cell = get_vmerge_block(tbl, r, c)
  if not r_start then return end

  local root_row = tbl.rows[r_start]
  local idx
  for i, cl in ipairs(root_row.cells) do
    if cl.col_idx == c then
      idx = i
      break
    end
  end
  if not idx or idx >= #root_row.cells then return end

  local next_cell = root_row.cells[idx + 1]
  if cell.rowspan ~= next_cell.rowspan then
    vim.notify('Fey: Cannot swap logical cells with different rowspans.', vim.log.levels.ERROR)
    return
  end

  local new_c1_col = cell.col_idx + next_cell.colspan
  local new_c2_col = cell.col_idx

  for i = 0, span - 1 do
    local cur_r = r_start + i
    local cur_row = tbl.rows[cur_r]
    local c1, c2
    for _, cl in ipairs(cur_row.cells) do
      if cl.col_idx == cell.col_idx then c1 = cl end
      if cl.col_idx == next_cell.col_idx then c2 = cl end
    end
    if c1 and c2 then
      c1.col_idx = new_c1_col
      c2.col_idx = new_c2_col
    end
    table.sort(cur_row.cells, function(a, b) return a.col_idx < b.col_idx end)
  end

  sync_boundaries(tbl)
  tbl:reformat()
end

function TableOps.move_cell_up()
  local tbl, r, c = TableOps.get_ctx()
  if not tbl or r <= 1 then return end

  local r2, span2, cell2 = get_vmerge_block(tbl, r, c)
  if not r2 or r2 <= 1 then return end

  local r1, span1, cell1 = get_vmerge_block(tbl, r2 - 1, c)
  if not r1 then return end

  if cell1.colspan ~= cell2.colspan then
    vim.notify('Fey: Cannot swap logical cells with different colspans.', vim.log.levels.ERROR)
    return
  end

  swap_vmerge_blocks(tbl, cell1.col_idx, r1, span1, r2, span2)
  sync_boundaries(tbl)
  tbl:reformat()
end

function TableOps.move_cell_down()
  local tbl, r, c = TableOps.get_ctx()
  if not tbl or r >= #tbl.rows then return end

  local r1, span1, cell1 = get_vmerge_block(tbl, r, c)
  if not r1 or (r1 + span1 > #tbl.rows) then return end

  local r2, span2, cell2 = get_vmerge_block(tbl, r1 + span1, c)
  if not r2 then return end

  if cell1.colspan ~= cell2.colspan then
    vim.notify('Fey: Cannot swap logical cells with different colspans.', vim.log.levels.ERROR)
    return
  end

  swap_vmerge_blocks(tbl, cell1.col_idx, r1, span1, r2, span2)
  sync_boundaries(tbl)
  tbl:reformat()
end

function TableOps.merge_cell_right()
  local tbl, r, c = TableOps.get_ctx()
  if not tbl then return end

  local r_start, _, cell = get_vmerge_block(tbl, r, c)
  if not r_start then return end

  local root_row = tbl.rows[r_start]
  local idx
  for i, cl in ipairs(root_row.cells) do
    if cl.col_idx == cell.col_idx then
      idx = i
      break
    end
  end
  if not idx or idx == #root_row.cells then return end

  local target = root_row.cells[idx + 1]
  if target.rowspan ~= cell.rowspan then
    vim.notify('Fey: Cannot merge logical cells with different cross-axis rowspans.', vim.log.levels.ERROR)
    return
  end

  for _, ln in ipairs(target.lines) do
    table.insert(cell.lines, ln)
  end
  cell.colspan = cell.colspan + target.colspan
  cell:update_display_len()
  table.remove(root_row.cells, idx + 1)

  if cell.rowspan > 1 then
    for step = 1, cell.rowspan - 1 do
      local next_row = tbl.rows[r_start + step]
      if next_row then
        local p_cell, rm_idx
        for ni, nc in ipairs(next_row.cells) do
          if nc.col_idx == target.col_idx then
            rm_idx = ni
          elseif nc.col_idx == cell.col_idx then
            p_cell = nc
          end
        end
        if rm_idx then table.remove(next_row.cells, rm_idx) end
        if p_cell then p_cell.colspan = cell.colspan end
      end
    end
  end

  sync_boundaries(tbl)
  tbl:reformat()
end

function TableOps.merge_cell_down()
  local tbl, r, c = TableOps.get_ctx()
  if not tbl then return end

  local r_start, span, cell = get_vmerge_block(tbl, r, c)
  if not r_start or (r_start + span > #tbl.rows) then return end

  local _, _, target = get_vmerge_block(tbl, r_start + span, c)
  if not target or target.colspan ~= cell.colspan then
    vim.notify('Fey: Cannot merge logical cells with different cross-axis colspans.', vim.log.levels.ERROR)
    return
  end

  for _, ln in ipairs(target.lines) do
    table.insert(cell.lines, ln)
  end
  cell.rowspan = cell.rowspan + target.rowspan
  cell:update_display_len()

  target.rowspan = 0
  target.lines = {}
  target:update_display_len()

  sync_boundaries(tbl)
  tbl:reformat()
end

function TableOps.unmerge_cells()
  local tbl, r, c = TableOps.get_ctx()
  if not tbl then return end

  local r_start, _, cell = get_vmerge_block(tbl, r, c)
  if not r_start then return end

  local row = tbl.rows[r_start]
  local idx
  for i, cl in ipairs(row.cells) do
    if cl.col_idx == cell.col_idx then
      idx = i
      break
    end
  end
  if not cell or (cell.colspan == 1 and cell.rowspan == 1) then return end

  local orig_colspan = cell.colspan
  local orig_rowspan = cell.rowspan
  local c_idx = cell.col_idx

  cell.colspan = 1
  cell.rowspan = 1

  for extra_c = 1, orig_colspan - 1 do
    local new_c = c_idx + extra_c
    local new_cell = TableCell:new({ row_idx = r_start, col_idx = new_c, colspan = 1, rowspan = 1, lines = {} })
    table.insert(row.cells, idx + extra_c, new_cell)
  end

  for extra_r = 1, orig_rowspan - 1 do
    local next_row = tbl.rows[r_start + extra_r]
    if next_row then
      local p_idx
      for ni, nc in ipairs(next_row.cells) do
        if nc.col_idx == c_idx and nc.rowspan == 0 then
          p_idx = ni
          break
        end
      end
      if p_idx then table.remove(next_row.cells, p_idx) end

      for extra_c = 0, orig_colspan - 1 do
        local new_c = c_idx + extra_c
        local new_cell = TableCell:new({ row_idx = r_start + extra_r, col_idx = new_c, colspan = 1, rowspan = 1, lines = {} })

        local ins_idx = 1
        while ins_idx <= #next_row.cells and next_row.cells[ins_idx].col_idx < new_c do
          ins_idx = ins_idx + 1
        end
        table.insert(next_row.cells, ins_idx, new_cell)
      end
    end
  end

  sync_boundaries(tbl)
  tbl:reformat()
end

return TableOps
