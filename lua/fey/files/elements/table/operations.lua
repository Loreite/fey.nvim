local TableRow = require('fey.files.elements.table.row')
local TableCell = require('fey.files.elements.table.cell')
local Table = require('fey.files.elements.table')
local ts_utils = require('fey.utils.treesitter')

local TableOps = {}

function TableOps.get_ctx()
  local tbl = Table.from_current_node()
  if not tbl then return nil, 1, 1 end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local r, c = 1, 1

  -- Support parsing cursor contexts over both cell content boundaries and standard rows
  local cell_node = ts_utils.get_node_at_cursor(cursor)
  local target_node = nil
  local curr = cell_node
  while curr do
    if curr:type() == 'cell' or curr:type() == 'cbi_cell' then
      target_node = curr
      break
    end
    curr = curr:parent()
  end

  if target_node then
    local s_row, s_col = target_node:start()
    local mapped = tbl.node_map[('%d,%d'):format(s_row, s_col)]
    if mapped then
      r, c = mapped.r, mapped.c
    end
  end

  return tbl, r, c
end

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

local function get_vmerge_block(tbl, r, c)
  local start_r = r
  local cell = nil
  while start_r >= 1 do
    for _, cl in ipairs(tbl.rows[start_r].cells) do
      if cl.col_idx <= c and (cl.col_idx + cl.colspan - 1) >= c then
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

local function swap_vmerge_blocks(tbl, c_start, colspan, r1, span1, r2, span2)
  -- Extract cells for the entire block spanning c_start .. c_start + colspan - 1
  local extracted = {}
  for i = r1, r2 + span2 - 1 do
    local row = tbl.rows[i]
    extracted[i] = {}
    local to_remove = {}
    for j, cl in ipairs(row.cells) do
      if cl.col_idx >= c_start and (cl.col_idx + cl.colspan - 1) <= (c_start + colspan - 1) then
        table.insert(extracted[i], cl)
        table.insert(to_remove, j)
      end
    end
    for k = #to_remove, 1, -1 do
      table.remove(row.cells, to_remove[k])
    end
  end

  local blockA, blockB = {}, {}
  for i = r1, r1 + span1 - 1 do
    table.insert(blockA, extracted[i])
  end
  for i = r2, r2 + span2 - 1 do
    table.insert(blockB, extracted[i])
  end

  for i, row_cells in ipairs(blockB) do
    for _, cl in ipairs(row_cells) do
      cl.row_idx = r1 + i - 1
    end
  end
  for i, row_cells in ipairs(blockA) do
    for _, cl in ipairs(row_cells) do
      cl.row_idx = r1 + span2 + i - 1
    end
  end

  local new_seq = {}
  for _, row_cells in ipairs(blockB) do
    table.insert(new_seq, row_cells)
  end
  for _, row_cells in ipairs(blockA) do
    table.insert(new_seq, row_cells)
  end

  for i = r1, r2 + span2 - 1 do
    local row = tbl.rows[i]
    local ins_cls = new_seq[i - r1 + 1]
    for _, ins_cl in ipairs(ins_cls) do
      local ins_idx = 1
      while ins_idx <= #row.cells and row.cells[ins_idx].col_idx < ins_cl.col_idx do
        ins_idx = ins_idx + 1
      end
      table.insert(row.cells, ins_idx, ins_cl)
    end
  end
end

function TableOps.reformat()
  local tbl = TableOps.get_ctx()
  if tbl then tbl:reformat() end
end

function TableOps.insert_row_after()
  local tbl, r, c = TableOps.get_ctx()
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

  tbl:sync_boundaries()
  tbl:reformat(r + 1, c)
end

function TableOps.insert_row_before()
  local tbl, r, c = TableOps.get_ctx()
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

  tbl:sync_boundaries()
  tbl:reformat(r, c)
end

function TableOps.delete_row()
  local tbl, r, c = TableOps.get_ctx()
  if not tbl or #tbl.rows <= 1 then return end

  table.remove(tbl.rows, r)
  for i = r, #tbl.rows do
    tbl.rows[i].line = i
    for _, cl in ipairs(tbl.rows[i].cells) do
      cl.row_idx = i
    end
  end

  tbl:sync_boundaries()
  tbl:reformat(math.min(r, #tbl.rows), c)
end

function TableOps.insert_col_before()
  local tbl, r, c = TableOps.get_ctx()
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

  tbl:sync_boundaries()
  tbl:reformat(r, c + 1)
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

  tbl:sync_boundaries()
  tbl:reformat(r, c)
end

function TableOps.move_col_left()
  local tbl, r, c = TableOps.get_ctx()
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

  tbl:sync_boundaries()
  tbl:reformat(r, c - w1)
end

function TableOps.delete_col()
  local tbl, r, c = TableOps.get_ctx()
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

  tbl:sync_boundaries()
  tbl:reformat(r, math.max(1, math.min(c, tbl.col_count)))
end

function TableOps.move_col_right()
  local tbl, r, c = TableOps.get_ctx()
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

  tbl:sync_boundaries()
  tbl:reformat(r, c + w2)
end

function TableOps.move_row_up()
  local tbl, r, c = TableOps.get_ctx()
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

  tbl:sync_boundaries()
  tbl:reformat(r - (r1_end - r1_start + 1), c)
end

function TableOps.move_row_down()
  local tbl, r, c = TableOps.get_ctx()
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

  tbl:sync_boundaries()
  tbl:reformat(r + (r2_end - r2_start + 1), c)
end

function TableOps.move_cell_left()
  local tbl, r, c = TableOps.get_ctx()
  if not tbl then return end

  local r_start, span, cell = get_vmerge_block(tbl, r, c)
  if not r_start or cell.col_idx <= 1 then return end

  local obstacle_c_end = cell.col_idx - 1
  local target_c_start = obstacle_c_end
  local changed = true

  while changed do
    changed = false
    for cur_r = r_start, r_start + span - 1 do
      local row = tbl.rows[cur_r]
      for _, cl in ipairs(row.cells) do
        local c_start = cl.col_idx
        local c_end = cl.col_idx + (cl.colspan or 1) - 1
        if cl.rowspan == 0 then
          local _, _, root_c = get_vmerge_block(tbl, cur_r, cl.col_idx)
          if root_c then
            c_start = root_c.col_idx
            c_end = root_c.col_idx + root_c.colspan - 1
          end
        end

        if c_end >= target_c_start and c_start < target_c_start then
          target_c_start = c_start
          changed = true
        end
      end
    end
  end

  for cur_r = r_start, r_start + span - 1 do
    local row = tbl.rows[cur_r]
    for _, cl in ipairs(row.cells) do
      if cl.col_idx >= target_c_start and cl.col_idx <= obstacle_c_end then
        local root_r, root_span = get_vmerge_block(tbl, cur_r, cl.col_idx)
        if root_r < r_start or (root_r + root_span - 1) > r_start + span - 1 then
          vim.notify('Fey: Cannot jump over cell that extends vertically outside the moving bounds.', vim.log.levels.ERROR)
          return
        end
      end
    end
  end

  local shift_right = cell.colspan
  local shift_left = obstacle_c_end - target_c_start + 1
  local orig_col = cell.col_idx

  for cur_r = r_start, r_start + span - 1 do
    local row = tbl.rows[cur_r]
    for _, cl in ipairs(row.cells) do
      if cl.col_idx >= orig_col and cl.col_idx <= orig_col + cell.colspan - 1 then
        cl.col_idx = cl.col_idx - shift_left
      elseif cl.col_idx >= target_c_start and cl.col_idx <= obstacle_c_end then
        cl.col_idx = cl.col_idx + shift_right
      end
    end
    table.sort(row.cells, function(a, b) return a.col_idx < b.col_idx end)
  end

  tbl:sync_boundaries()
  tbl:reformat(r_start, orig_col - shift_left)
end

function TableOps.move_cell_right()
  local tbl, r, c = TableOps.get_ctx()
  if not tbl then return end

  local r_start, span, cell = get_vmerge_block(tbl, r, c)
  if not r_start then return end

  local obstacle_c_start = cell.col_idx + cell.colspan
  if obstacle_c_start > tbl.col_count then return end

  local target_c_end = obstacle_c_start
  local changed = true

  while changed do
    changed = false
    for cur_r = r_start, r_start + span - 1 do
      local row = tbl.rows[cur_r]
      for _, cl in ipairs(row.cells) do
        if cl.rowspan > 0 and cl.col_idx <= target_c_end and (cl.col_idx + cl.colspan - 1) > target_c_end then
          target_c_end = cl.col_idx + cl.colspan - 1
          changed = true
        end
        if cl.rowspan == 0 and cl.col_idx <= target_c_end then
          local _, _, root_c = get_vmerge_block(tbl, cur_r, cl.col_idx)
          if root_c and (root_c.col_idx + root_c.colspan - 1) > target_c_end then
            target_c_end = root_c.col_idx + root_c.colspan - 1
            changed = true
          end
        end
      end
    end
  end

  for cur_r = r_start, r_start + span - 1 do
    local row = tbl.rows[cur_r]
    for _, cl in ipairs(row.cells) do
      if cl.col_idx >= obstacle_c_start and cl.col_idx <= target_c_end then
        local root_r, root_span = get_vmerge_block(tbl, cur_r, cl.col_idx)
        if root_r < r_start or (root_r + root_span - 1) > r_start + span - 1 then
          vim.notify('Fey: Cannot jump over cell that extends vertically outside the moving bounds.', vim.log.levels.ERROR)
          return
        end
      end
    end
  end

  local shift_left = cell.colspan
  local shift_right = target_c_end - obstacle_c_start + 1
  local orig_col = cell.col_idx

  for cur_r = r_start, r_start + span - 1 do
    local row = tbl.rows[cur_r]
    for _, cl in ipairs(row.cells) do
      if cl.col_idx >= orig_col and cl.col_idx <= orig_col + cell.colspan - 1 then
        cl.col_idx = cl.col_idx + shift_right
      elseif cl.col_idx >= obstacle_c_start and cl.col_idx <= target_c_end then
        cl.col_idx = cl.col_idx - shift_left
      end
    end
    table.sort(row.cells, function(a, b) return a.col_idx < b.col_idx end)
  end

  tbl:sync_boundaries()
  tbl:reformat(r_start, orig_col + shift_right)
end

function TableOps.merge_cell_up()
  local tbl, r, c = TableOps.get_ctx()
  if not tbl then return end

  local r_start, span, cell = get_vmerge_block(tbl, r, c)
  if not r_start or r_start <= 1 then return end

  local target_r_end = r_start - 1
  local target_r_start = target_r_end
  local block_cells = {}
  local changed = true

  -- Determine full bounding box of cells immediately above
  while changed do
    changed = false
    for cur_r = target_r_start, target_r_end do
      local row = tbl.rows[cur_r]
      for _, cl in ipairs(row.cells) do
        if cl.col_idx < cell.col_idx + cell.colspan and (cl.col_idx + cl.colspan - 1) >= cell.col_idx then
          local root_r, _, _ = get_vmerge_block(tbl, cur_r, cl.col_idx)
          if root_r and root_r < target_r_start then
            target_r_start = root_r
            changed = true
          end
        end
      end
    end
  end

  -- Validate horizontal bounds don't protrude outside our selection
  for cur_r = target_r_start, target_r_end do
    local row = tbl.rows[cur_r]
    for _, cl in ipairs(row.cells) do
      if cl.col_idx < cell.col_idx + cell.colspan and (cl.col_idx + cl.colspan - 1) >= cell.col_idx then
        local _, _, root_c = get_vmerge_block(tbl, cur_r, cl.col_idx)
        if root_c.col_idx < cell.col_idx or (root_c.col_idx + root_c.colspan - 1) > cell.col_idx + cell.colspan - 1 then
          vim.notify('Fey: Target cells extend horizontally outside the merge bounds.', vim.log.levels.ERROR)
          return
        end
        if root_c.rowspan > 0 and not vim.tbl_contains(block_cells, root_c) then table.insert(block_cells, root_c) end
      end
    end
  end

  -- Absorb content top-to-bottom
  local new_lines = {}
  for _, bc in ipairs(block_cells) do
    for _, ln in ipairs(bc.lines) do
      if vim.trim(ln) ~= '' then table.insert(new_lines, ln) end
    end
  end
  for _, ln in ipairs(cell.lines) do
    if vim.trim(ln) ~= '' then table.insert(new_lines, ln) end
  end
  cell.lines = new_lines

  local absorbed_height = target_r_end - target_r_start + 1
  cell.rowspan = cell.rowspan + absorbed_height
  if cell.update_display_len then cell:update_display_len() end

  -- Reconstruct the rows: teleport root cell up, cascade new shadows downward
  for cur_r = target_r_start, r_start + span - 1 do
    local row = tbl.rows[cur_r]
    local new_cells = {}

    for _, cl in ipairs(row.cells) do
      if cl.col_idx < cell.col_idx or cl.col_idx >= cell.col_idx + cell.colspan then table.insert(new_cells, cl) end
    end

    local root_or_shadow
    if cur_r == target_r_start then
      cell.row_idx = target_r_start
      root_or_shadow = cell
    else
      root_or_shadow =
        TableCell:new({ row_idx = cur_r, col_idx = cell.col_idx, colspan = cell.colspan, rowspan = 0, lines = {} })
    end

    local ins_idx = 1
    while ins_idx <= #new_cells and new_cells[ins_idx].col_idx < cell.col_idx do
      ins_idx = ins_idx + 1
    end

    table.insert(new_cells, ins_idx, root_or_shadow)
    row.cells = new_cells
  end

  -- Move trapped HRs up to the top boundary of the newly merged block
  local merge_top = target_r_start
  local merge_bottom = r_start + span - 1

  local top_idx, bot_idx
  for i, item in ipairs(tbl.logical_grid) do
    if not item.type and item.line == merge_top then top_idx = i end
    if not item.type and item.line == merge_bottom then bot_idx = i end
  end

  if top_idx and bot_idx then
    local trapped_hrs = {}
    local new_grid = {}
    for i, item in ipairs(tbl.logical_grid) do
      if i > top_idx and i < bot_idx and item.type == 'hr' then
        table.insert(trapped_hrs, item)
      else
        table.insert(new_grid, item)
      end
    end

    local new_top_idx
    for i, item in ipairs(new_grid) do
      if not item.type and item.line == merge_top then
        new_top_idx = i
        break
      end
    end

    if new_top_idx then
      for _, hr in ipairs(trapped_hrs) do
        table.insert(new_grid, new_top_idx, hr)
        new_top_idx = new_top_idx + 1
      end
    end
    tbl.logical_grid = new_grid
  end

  tbl:sync_boundaries()
  tbl:reformat(target_r_start, cell.col_idx)
end

function TableOps.merge_cell_down()
  local tbl, r, c = TableOps.get_ctx()
  if not tbl then return end

  local r_start, span, cell = get_vmerge_block(tbl, r, c)
  if not cell then return end
  if not r_start or (r_start + span > #tbl.rows) then return end

  local target_r = r_start + span
  local block_cells = {}
  local target_r_end = target_r
  local changed = true

  while changed do
    changed = false
    for cur_r = target_r, target_r_end do
      if cur_r <= #tbl.rows then
        local row = tbl.rows[cur_r]
        for _, cl in ipairs(row.cells) do
          if cl.col_idx < cell.col_idx + cell.colspan and (cl.col_idx + cl.colspan - 1) >= cell.col_idx then
            local root_r, root_span, _ = get_vmerge_block(tbl, cur_r, cl.col_idx)
            if root_r + root_span - 1 > target_r_end then
              target_r_end = root_r + root_span - 1
              changed = true
            end
          end
        end
      end
    end
  end

  for cur_r = target_r, target_r_end do
    local row = tbl.rows[cur_r]
    for _, cl in ipairs(row.cells) do
      if cl.col_idx < cell.col_idx + cell.colspan and (cl.col_idx + cl.colspan - 1) >= cell.col_idx then
        local _, _, root_c = get_vmerge_block(tbl, cur_r, cl.col_idx)
        if
          root_c
          and ((root_c.col_idx < cell.col_idx) or (root_c.col_idx + root_c.colspan - 1) > (cell.col_idx + cell.colspan - 1))
        then
          vim.notify('Fey: Target cells extend horizontally outside the merge bounds.', vim.log.levels.ERROR)
          return
        end
        if root_c and root_c.rowspan > 0 and not vim.tbl_contains(block_cells, root_c) then
          table.insert(block_cells, root_c)
        end
      end
    end
  end

  local new_lines = {}
  for _, ln in ipairs(cell.lines) do
    if vim.trim(ln) ~= '' then table.insert(new_lines, ln) end
  end
  for _, bc in ipairs(block_cells) do
    for _, ln in ipairs(bc.lines) do
      if vim.trim(ln) ~= '' then table.insert(new_lines, ln) end
    end
  end

  if #new_lines == 0 then table.insert(new_lines, '') end
  cell.lines = new_lines

  cell.rowspan = cell.rowspan + (target_r_end - target_r + 1)
  cell:update_display_len()

  for cur_r = target_r, target_r_end do
    local row = tbl.rows[cur_r]
    local new_cells = {}
    for _, cl in ipairs(row.cells) do
      if cl.col_idx < cell.col_idx or cl.col_idx >= cell.col_idx + cell.colspan then table.insert(new_cells, cl) end
    end
    -- Unify broken trailing shadow cells into a single identical shadow clone on the target row
    local shadow = TableCell:new({ row_idx = cur_r, col_idx = cell.col_idx, colspan = cell.colspan, rowspan = 0, lines = {} })
    local ins_idx = 1
    while ins_idx <= #new_cells and new_cells[ins_idx].col_idx < cell.col_idx do
      ins_idx = ins_idx + 1
    end
    table.insert(new_cells, ins_idx, shadow)
    row.cells = new_cells
  end

  -- Move trapped HRs down to the bottom boundary of the newly merged block
  local merge_top = r_start
  local merge_bottom = target_r_end

  local top_idx, bot_idx
  for i, item in ipairs(tbl.logical_grid) do
    if not item.type and item.line == merge_top then top_idx = i end
    if not item.type and item.line == merge_bottom then bot_idx = i end
  end

  if top_idx and bot_idx then
    local trapped_hrs = {}
    local new_grid = {}
    for i, item in ipairs(tbl.logical_grid) do
      if i > top_idx and i < bot_idx and item.type == 'hr' then
        table.insert(trapped_hrs, item)
      else
        table.insert(new_grid, item)
      end
    end

    local new_bot_idx
    for i, item in ipairs(new_grid) do
      if not item.type and item.line == merge_bottom then
        new_bot_idx = i
        break
      end
    end

    if new_bot_idx then
      for _, hr in ipairs(trapped_hrs) do
        table.insert(new_grid, new_bot_idx + 1, hr)
        new_bot_idx = new_bot_idx + 1
      end
    end
    tbl.logical_grid = new_grid
  end

  tbl:sync_boundaries()
  tbl:reformat(r_start, cell.col_idx)
end

function TableOps.merge_cell_right()
  local tbl, r, c = TableOps.get_ctx()
  if not tbl then return end

  local r_start, span, cell = get_vmerge_block(tbl, r, c)
  if not r_start then return end

  local target_c = cell.col_idx + cell.colspan
  if target_c > tbl.col_count then return end

  local block_cells = {}
  local target_c_end = target_c
  local changed = true

  while changed do
    changed = false
    for cur_r = r_start, r_start + span - 1 do
      local row = tbl.rows[cur_r]
      for _, cl in ipairs(row.cells) do
        if cl.col_idx <= target_c_end and (cl.col_idx + cl.colspan - 1) >= target_c then
          local root_r, root_span, root_c = get_vmerge_block(tbl, cur_r, cl.col_idx)
          if root_c.col_idx + root_c.colspan - 1 > target_c_end then
            target_c_end = root_c.col_idx + root_c.colspan - 1
            changed = true
          end
        end
      end
    end
  end

  for cur_r = r_start, r_start + span - 1 do
    local row = tbl.rows[cur_r]
    for _, cl in ipairs(row.cells) do
      if cl.col_idx <= target_c_end and (cl.col_idx + cl.colspan - 1) >= target_c then
        local root_r, root_span, root_c = get_vmerge_block(tbl, cur_r, cl.col_idx)
        if root_r < r_start or (root_r + root_span - 1) > r_start + span - 1 then
          vim.notify('Fey: Target cells extend vertically outside the merge bounds.', vim.log.levels.ERROR)
          return
        end
        if root_c.rowspan > 0 and not vim.tbl_contains(block_cells, root_c) then table.insert(block_cells, root_c) end
      end
    end
  end

  local new_lines = {}
  for _, ln in ipairs(cell.lines) do
    if vim.trim(ln) ~= '' then table.insert(new_lines, ln) end
  end
  for _, bc in ipairs(block_cells) do
    for _, ln in ipairs(bc.lines) do
      if vim.trim(ln) ~= '' then table.insert(new_lines, ln) end
    end
  end

  if #new_lines == 0 then table.insert(new_lines, '') end
  cell.lines = new_lines

  cell.colspan = cell.colspan + (target_c_end - target_c + 1)
  cell:update_display_len()

  for cur_r = r_start, r_start + span - 1 do
    local row = tbl.rows[cur_r]
    local new_cells = {}
    for _, cl in ipairs(row.cells) do
      if cl.col_idx < target_c or cl.col_idx > target_c_end then
        if cl.col_idx == cell.col_idx and cur_r > r_start then cl.colspan = cell.colspan end
        table.insert(new_cells, cl)
      end
    end
    row.cells = new_cells
  end

  tbl:sync_boundaries()
  tbl:reformat(r_start, cell.col_idx)
end

function TableOps.merge_cell_left()
  local tbl, r, c = TableOps.get_ctx()
  if not tbl then return end

  local r_start, span, cell = get_vmerge_block(tbl, r, c)
  if not cell then return end
  if not r_start or cell.col_idx <= 1 then return end

  local target_c_end = cell.col_idx - 1
  local target_c_start = target_c_end
  local block_cells = {}
  local changed = true

  -- Determine full bounding box of cells immediately to the left
  while changed do
    changed = false
    for cur_r = r_start, r_start + span - 1 do
      local row = tbl.rows[cur_r]
      for _, cl in ipairs(row.cells) do
        if cl.col_idx <= target_c_end and (cl.col_idx + cl.colspan - 1) >= target_c_start then
          local _, _, root_c = get_vmerge_block(tbl, cur_r, cl.col_idx)
          if root_c and root_c.col_idx < target_c_start then
            target_c_start = root_c.col_idx
            changed = true
          end
        end
      end
    end
  end

  -- Validate vertical bounds don't protrude outside our selection
  for cur_r = r_start, r_start + span - 1 do
    local row = tbl.rows[cur_r]
    for _, cl in ipairs(row.cells) do
      if cl.col_idx <= target_c_end and (cl.col_idx + cl.colspan - 1) >= target_c_start then
        local root_r, root_span, root_c = get_vmerge_block(tbl, cur_r, cl.col_idx)
        if root_r < r_start or (root_r + root_span - 1) > r_start + span - 1 then
          vim.notify('Fey: Target cells extend vertically outside the merge bounds.', vim.log.levels.ERROR)
          return
        end
        if root_c and root_c.rowspan > 0 and not vim.tbl_contains(block_cells, root_c) then
          table.insert(block_cells, root_c)
        end
      end
    end
  end

  -- Absorb content left-to-right (prepended to current cell)
  local new_lines = {}
  for _, bc in ipairs(block_cells) do
    for _, ln in ipairs(bc.lines) do
      if vim.trim(ln) ~= '' then table.insert(new_lines, ln) end
    end
  end
  for _, ln in ipairs(cell.lines) do
    if vim.trim(ln) ~= '' then table.insert(new_lines, ln) end
  end

  cell.lines = new_lines
  local absorbed_width = target_c_end - target_c_start + 1
  local new_col_idx = target_c_start
  local orig_col_idx = cell.col_idx

  cell.colspan = cell.colspan + absorbed_width
  if cell.update_display_len then cell:update_display_len() end

  -- Reconstruct the rows: drop absorbed cells, shift the root and shadow columns
  for cur_r = r_start, r_start + span - 1 do
    local row = tbl.rows[cur_r]
    local new_cells = {}
    for _, cl in ipairs(row.cells) do
      if cl.col_idx < target_c_start or cl.col_idx > target_c_end then
        if cl.col_idx == orig_col_idx then
          cl.col_idx = new_col_idx
          cl.colspan = cell.colspan
        end
        table.insert(new_cells, cl)
      end
    end
    table.sort(new_cells, function(a, b) return a.col_idx < b.col_idx end)
    row.cells = new_cells
  end

  tbl:sync_boundaries()
  tbl:reformat(r_start, cell.col_idx)
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

  tbl:sync_boundaries()
  tbl:reformat(r_start, c_idx)
end

function TableOps.table_cell_content_merge(direction, before)
  local tbl, r, c = TableOps.get_ctx()
  if not tbl then return end

  local r_start, span, cell = get_vmerge_block(tbl, r, c)
  if not r_start then return end

  local target_cell = nil

  if direction == 'vertical' then
    local search_r = before and (r_start - 1) or (r_start + span)
    if search_r >= 1 and search_r <= #tbl.rows then
      local _, _, tc = get_vmerge_block(tbl, search_r, cell.col_idx)
      target_cell = tc
    end
  elseif direction == 'horizontal' then
    local search_c = before and (cell.col_idx - 1) or (cell.col_idx + cell.colspan)
    if search_c >= 1 and search_c <= tbl.col_count then
      local _, _, tc = get_vmerge_block(tbl, r_start, search_c)
      target_cell = tc
    end
  end

  if not target_cell then return end

  local new_lines = {}
  if before then
    for _, ln in ipairs(target_cell.lines) do
      if vim.trim(ln) ~= '' then table.insert(new_lines, vim.trim(ln)) end
    end
    for _, ln in ipairs(cell.lines) do
      if vim.trim(ln) ~= '' then table.insert(new_lines, vim.trim(ln)) end
    end
  else
    for _, ln in ipairs(cell.lines) do
      if vim.trim(ln) ~= '' then table.insert(new_lines, vim.trim(ln)) end
    end
    for _, ln in ipairs(target_cell.lines) do
      if vim.trim(ln) ~= '' then table.insert(new_lines, vim.trim(ln)) end
    end
  end

  if #new_lines == 0 then table.insert(new_lines, '') end
  cell.lines = new_lines
  target_cell.lines = { '' }

  if cell.update_display_len then cell:update_display_len() end
  if target_cell.update_display_len then target_cell:update_display_len() end

  tbl:sync_boundaries()
  tbl:reformat(r_start, cell.col_idx)
end

function TableOps.table_cell_line_flatten(before)
  local tbl, r, c = TableOps.get_ctx()
  if not tbl then return end

  local r_start, _, cell = get_vmerge_block(tbl, r, c)
  if not r_start or #cell.lines <= 1 then return end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local node = ts_utils.get_node_at_cursor(cursor)
  local target_node = nil
  local curr = node

  while curr do
    if curr:type() == 'cell' or curr:type() == 'cb_cell' or curr:type() == 'cbi_cell' then
      target_node = curr
      break
    end
    curr = curr:parent()
  end

  local target_line_idx = 1
  if target_node and cell.node_to_line then target_line_idx = cell.node_to_line[target_node:id()] or 1 end

  if before then
    if target_line_idx > 1 then
      cell.lines[target_line_idx - 1] = cell.lines[target_line_idx - 1] .. ' ' .. cell.lines[target_line_idx]
      table.remove(cell.lines, target_line_idx)
    end
  else
    if target_line_idx < #cell.lines then
      cell.lines[target_line_idx] = cell.lines[target_line_idx] .. ' ' .. cell.lines[target_line_idx + 1]
      table.remove(cell.lines, target_line_idx + 1)
    end
  end

  if cell.update_display_len then cell:update_display_len() end
  tbl:sync_boundaries()
  tbl:reformat(r_start, cell.col_idx)
end

---Helper function to move the cursor to a target logical cell
---@param tbl FeyTable
---@param r integer Target row index
---@param c integer Target column index
local function goto_logical_cell(tbl, r, c)
  -- Clamp target indices to grid boundaries
  r = math.max(1, math.min(r, #tbl.rows))
  c = math.max(1, math.min(c, tbl.col_count))

  -- Dry-run draw to compute current physical cell positions
  local _, cell_positions = tbl:draw()

  -- Find root cell (handling vertical merge shadow cells)
  local target_cell = nil
  for root_r = r, 1, -1 do
    for _, cl in ipairs(tbl.rows[root_r].cells) do
      if cl.col_idx <= c and (cl.col_idx + cl.colspan - 1) >= c then
        if cl.rowspan > 0 then
          target_cell = cl
          break
        end
      end
    end
    if target_cell then break end
  end

  if target_cell and cell_positions[target_cell] then
    local _, start_col = tbl.node:range()
    local target_line = tbl.range.start_line - 1 + cell_positions[target_cell].line
    local target_col = start_col + cell_positions[target_cell].col
    vim.api.nvim_win_set_cursor(0, { target_line, target_col })
  end
end

function TableOps.goto_cell_up()
  local tbl, r, c = TableOps.get_ctx()
  if not tbl then return end

  local r_start, _, _ = get_vmerge_block(tbl, r, c)
  if not r_start or r_start <= 1 then return end

  goto_logical_cell(tbl, r_start - 1, c)
end

function TableOps.goto_cell_down()
  local tbl, r, c = TableOps.get_ctx()
  if not tbl then return end

  local r_start, span, _ = get_vmerge_block(tbl, r, c)
  if not r_start or (r_start + span > #tbl.rows) then return end

  goto_logical_cell(tbl, r_start + span, c)
end

function TableOps.goto_cell_left()
  local tbl, r, c = TableOps.get_ctx()
  if not tbl then return end

  local _, _, cell = get_vmerge_block(tbl, r, c)
  if not cell or cell.col_idx <= 1 then return end

  goto_logical_cell(tbl, r, cell.col_idx - 1)
end

function TableOps.goto_cell_right()
  local tbl, r, c = TableOps.get_ctx()
  if not tbl then return end

  local _, _, cell = get_vmerge_block(tbl, r, c)
  if not cell then return end

  local next_c = cell.col_idx + cell.colspan
  if next_c > tbl.col_count then return end

  goto_logical_cell(tbl, r, next_c)
end

return TableOps
