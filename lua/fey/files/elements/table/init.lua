local Range = require('fey.files.elements.range')
local TableRow = require('fey.files.elements.table.row')
local TableCell = require('fey.files.elements.table.cell')
local ts_utils = require('fey.utils.treesitter')
local config = require('fey.config')
local utils = require('fey.utils')

---@class FeyTable
---@field logical_grid table[] Mixed array of boundary definitions and FeyTableRow references
---@field node_map table
---@field col_widths number[]
---@field rows FeyTableRow[]
---@field range FeyRange
---@field start_line integer
---@field start_col integer
---@field end_line integer
---@field node TSNode
---@field col_count integer
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
  local is_multi_line_mode = false
  local pending_hrs = 0 -- Track deferred HR boundaries

  local function commit_logical_row()
    if #current_physical_rows == 0 then return end

    local logical_row = TableRow:new({ table = tbl, line = #tbl.rows + 1 })

    local spans = (is_multi_line_mode and current_top_boundary and current_top_boundary.type ~= 'hr')
        and current_top_boundary.spans
      or nil

    -- Fallback to standard 1:1 columns if not bound by an active CBO/CBI span
    if not spans then
      spans = {}
      for i = 1, tbl.col_count do
        table.insert(spans, { span = 1, start = i, vmerge = false })
      end
    end

    local col_idx = 1
    for i, span_info in ipairs(spans) do
      local cell_lines = {}
      for _, phys_row in ipairs(current_physical_rows) do
        local cell_node = phys_row[i]
        if cell_node then
          -- Build O(1) node mapping linking physical TS coordinates to abstract grid coordinates
          local s_row, s_col = cell_node:start()
          tbl.node_map[('%d,%d'):format(s_row, s_col)] = { r = logical_row.line, c = col_idx }

          local content_node = cell_node:field('contents')[1]
          if content_node then
            local text = vim.treesitter.get_node_text(content_node, bufnr)
            table.insert(cell_lines, vim.trim(text))
          else
            table.insert(cell_lines, '')
          end
        end
      end

      -- Clean up trailing empty lines that might result from physical padding
      while #cell_lines > 1 and cell_lines[#cell_lines] == '' do
        table.remove(cell_lines)
      end

      if span_info.vmerge and #tbl.rows > 0 then
        -- Apply the lines to the cell in the previous valid row for this column block
        local prev_cell
        for r = #tbl.rows, 1, -1 do
          for _, c in ipairs(tbl.rows[r].cells) do
            if c.col_idx == col_idx and c.rowspan > 0 then
              prev_cell = c
              break
            end
          end
          if prev_cell then break end
        end

        if prev_cell then
          prev_cell.rowspan = prev_cell.rowspan + 1
          for _, ln in ipairs(cell_lines) do
            if vim.trim(ln) ~= '' then table.insert(prev_cell.lines, ln) end
          end
          prev_cell:update_display_len()
        end

        -- Insert a placeholder cell into this logical row so the grid respects the skip
        local cell = TableCell:new({
          row_idx = logical_row.line,
          col_idx = col_idx,
          colspan = span_info.span,
          rowspan = 0,
          lines = {},
        })
        logical_row:add_cell(cell)
      else
        local cell = TableCell:new({
          row_idx = logical_row.line,
          col_idx = col_idx,
          colspan = span_info.span,
          rowspan = 1,
          lines = cell_lines,
        })
        logical_row:add_cell(cell)
      end

      col_idx = col_idx + span_info.span
    end

    table.insert(tbl.rows, logical_row)
    table.insert(tbl.logical_grid, logical_row)
  end

  for child in node:iter_children() do
    local type = child:type()

    if type == 'row' then
      local cells = child:field('cell')
      if not has_seen_crown and tbl.col_count < 1 then
        has_seen_crown = true
        tbl.col_count = #cells
      end
      table.insert(current_physical_rows, cells)
    elseif type == 'hr' then
      if is_multi_line_mode then
        pending_hrs = pending_hrs + 1
      else
        commit_logical_row()
        current_physical_rows = {}

        local boundary = { type = type }
        table.insert(tbl.logical_grid, boundary)
        current_top_boundary = boundary
      end
    elseif utils.set({ 'cbi', 'cbo' })[type] then
      commit_logical_row()
      current_physical_rows = {}

      -- Flush pending HR boundaries immediately after committing the deferred region's logical row
      while pending_hrs > 0 do
        table.insert(tbl.logical_grid, { type = 'hr' })
        pending_hrs = pending_hrs - 1
      end

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

      local boundary = { type = type, spans = spans }
      table.insert(tbl.logical_grid, boundary)
      current_top_boundary = boundary

      if type == 'cbo' and not is_multi_line_mode then
        is_multi_line_mode = true
      elseif type == 'cbo' and is_multi_line_mode then
        is_multi_line_mode = false
      end

      if not has_seen_crown and #tbl.rows > 0 then has_seen_crown = true end
    end
  end
  commit_logical_row()

  -- Handle trailing hr instances
  while pending_hrs > 0 do
    table.insert(tbl.logical_grid, { type = 'hr' })
    pending_hrs = pending_hrs - 1
  end

  return tbl
end

function Table:calculate_widths(max_table_width)
  max_table_width = max_table_width or 120
  self.col_widths = {}
  for i = 1, self.col_count do
    self.col_widths[i] = 3
  end

  -- Apply single-column widths
  for _, row in ipairs(self.rows) do
    for _, cell in ipairs(row.cells) do
      if cell.colspan == 1 then
        local required = cell.display_len
        if cell.config.minw and cell.config.minw > required then required = cell.config.minw end
        if cell.config.maxw and cell.config.maxw < required then required = cell.config.maxw end
        self.col_widths[cell.col_idx] = math.max(self.col_widths[cell.col_idx], required)
      end
    end
  end

  -- Apply and distribute multi-column widths
  for _, row in ipairs(self.rows) do
    for _, cell in ipairs(row.cells) do
      if cell.colspan > 1 then
        local required = cell.display_len
        local current_span_width = 0
        for c = cell.col_idx, cell.col_idx + cell.colspan - 1 do
          current_span_width = current_span_width + self.col_widths[c]
        end
        current_span_width = current_span_width + (cell.colspan - 1) * 3

        if required > current_span_width then
          local diff = required - current_span_width
          local add_per_col = math.ceil(diff / cell.colspan)
          for c = cell.col_idx, cell.col_idx + cell.colspan - 1 do
            self.col_widths[c] = self.col_widths[c] + add_per_col
          end
        end
      end
    end
  end

  -- Limit maximum width constraint via degradation
  local total = 1
  for i = 1, self.col_count do
    total = total + self.col_widths[i] + 3
  end

  if total > max_table_width then
    local excess = total - max_table_width
    while excess > 0 do
      local largest_idx = 1
      local largest_val = 0
      for i = 1, self.col_count do
        if self.col_widths[i] > largest_val then
          largest_val = self.col_widths[i]
          largest_idx = i
        end
      end
      if largest_val <= 3 then break end
      self.col_widths[largest_idx] = self.col_widths[largest_idx] - 1
      excess = excess - 1
    end
  end
end

-- Local helper to chunk cell contents that exceed block width limits
local function wrap_lines(lines, max_w)
  local wrapped = {}
  for _, line in ipairs(lines) do
    if #line == 0 then
      table.insert(wrapped, '')
    else
      local current = ''
      for word in line:gmatch('%S+') do
        if #current + #word + 1 > max_w then
          if #current > 0 then
            table.insert(wrapped, vim.trim(current))
            current = word
          else
            table.insert(wrapped, word)
            current = ''
          end
        else
          current = current == '' and word or current .. ' ' .. word
        end
      end
      if #current > 0 then table.insert(wrapped, vim.trim(current)) end
    end
  end
  return wrapped
end

function Table:draw()
  self:calculate_widths(120)
  local rendered_lines = {}

  local function draw_boundary(b_type, spans)
    local chars = { hr = '=', cbo = '-', cbi = '~' }
    local fill = chars[b_type] or '-'
    local line = '+'

    if not spans then
      for i = 1, self.col_count do
        line = line .. string.rep(fill, self.col_widths[i] + 2) .. '+'
      end
    else
      local col_idx = 1
      for _, span_info in ipairs(spans) do
        local span_str = ''
        if span_info.vmerge then
          for i = 0, span_info.span - 1 do
            local c = col_idx + i
            local w = self.col_widths[c] + 2
            local spaces = string.rep(' ', w - 2)
            span_str = span_str .. '|' .. spaces .. '|'
            if i < span_info.span - 1 then span_str = span_str .. '*' end
          end
          span_str = span_str .. '+'
        else
          for i = 0, span_info.span - 1 do
            local c = col_idx + i
            local w = self.col_widths[c] + 2
            span_str = span_str .. string.rep(fill, w)
            if i < span_info.span - 1 then span_str = span_str .. '*' end
          end
          span_str = span_str .. '+'
        end
        line = line .. span_str
        col_idx = col_idx + span_info.span
      end
    end
    return line
  end

  -- Wrap cell contents to their respective span constraints
  for _, row in ipairs(self.rows) do
    for _, cell in ipairs(row.cells) do
      local max_w = 0
      for c = cell.col_idx, cell.col_idx + cell.colspan - 1 do
        max_w = max_w + self.col_widths[c]
      end
      max_w = max_w + (cell.colspan - 1) * 3
      cell.wrapped = wrap_lines(cell.lines, max_w)
    end
  end

  local row_phys_lines = {}
  for i = 1, #self.rows do
    row_phys_lines[i] = 1
  end
  for i, row in ipairs(self.rows) do
    for _, cell in ipairs(row.cells) do
      if cell.rowspan > 0 then
        local needed = #cell.wrapped
        local available = 0
        for r = i, i + cell.rowspan - 1 do
          available = available + row_phys_lines[r]
        end
        if needed > available then
          local diff = needed - available
          local var1 = math.floor(diff / cell.rowspan)
          local var2 = diff % cell.rowspan

          for r = i, i + cell.rowspan - 1 do
            local extra = var1 + (var2 < 1 and 0 or 1)
            row_phys_lines[r] = row_phys_lines[r] + extra
            var2 = var2 - 1
          end
        end
      end
    end
  end

  for _, item in ipairs(self.logical_grid) do
    if item.type == 'hr' or item.type == 'cbo' or item.type == 'cbi' then
      table.insert(rendered_lines, draw_boundary(item.type, item.spans))
    else
      local logical_row = item
      local row_idx = logical_row.line
      local phys_count = row_phys_lines[row_idx] or 1

      for l = 1, phys_count do
        local line_str = '|'
        local col_idx = 1

        while col_idx <= self.col_count do
          local cell = nil
          for _, c in ipairs(logical_row.cells) do
            if c.col_idx == col_idx then
              cell = c
              break
            end
          end

          -- Reverse lookup multi-row cell content from previous bounded instances
          local active_cell = cell
          if cell and cell.rowspan == 0 then
            for r = row_idx - 1, 1, -1 do
              for _, c in ipairs(self.rows[r].cells) do
                if c.col_idx == col_idx and c.rowspan > 0 then
                  active_cell = c
                  break
                end
              end
              if active_cell and active_cell.rowspan > 0 then break end
            end
          end

          local rendered_in_prev_rows = 0
          if active_cell and active_cell.row_idx < row_idx then
            for r = active_cell.row_idx, row_idx - 1 do
              rendered_in_prev_rows = rendered_in_prev_rows + (row_phys_lines[r] or 1)
            end
          end

          local text = ''
          if active_cell then
            local line_index = rendered_in_prev_rows + l
            text = active_cell.wrapped[line_index] or ''
          end

          local span = active_cell and active_cell.colspan or 1
          local w = 0
          for c = col_idx, col_idx + span - 1 do
            w = w + self.col_widths[c]
          end
          w = w + (span - 1) * 3

          local text_w = vim.api.nvim_strwidth(text)
          local pad_len = w - text_w
          if pad_len < 0 then pad_len = 0 end

          line_str = line_str .. ' ' .. text .. string.rep(' ', pad_len) .. ' |'
          col_idx = col_idx + span
        end
        table.insert(rendered_lines, line_str)
      end
    end
  end

  return rendered_lines
end

function Table:reformat()
  if not self.node then return false end
  local _, start_col = self.node:range()
  local indent = config:get_indent(start_col, vim.api.nvim_get_current_buf())

  local contents = vim.tbl_map(function(line) return ('%s%s'):format(indent, line) end, self:draw())
  local view = vim.fn.winsaveview() or {}

  vim.api.nvim_buf_set_lines(0, self.range.start_line - 1, self.range.end_line, false, contents)
  vim.fn.winrestview(view)
  return true
end

return Table
