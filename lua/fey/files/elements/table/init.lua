local Range = require('fey.files.elements.range')
local TableRow = require('fey.files.elements.table.row')
local TableCell = require('fey.files.elements.table.cell')
local ts_utils = require('fey.utils.treesitter')
local config = require('fey.config')
local utils = require('fey.utils')
local indent = require('fey.fey.indent')

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
  local pending_hrs = 0

  local function commit_logical_row()
    if #current_physical_rows == 0 then return end

    local logical_row = TableRow:new({ table = tbl, line = #tbl.rows + 1 })
    local spans = (is_multi_line_mode and current_top_boundary) and current_top_boundary.spans or nil

    if not spans then
      spans = {}
      for i = 1, tbl.col_count do
        table.insert(spans, { span = 1, start = i, vmerge = false })
      end
    end

    local col_idx = 1
    for i, span_info in ipairs(spans) do
      local cell_lines = {}
      local cell_nodes = {}
      for _, phys_row in ipairs(current_physical_rows) do
        local cell_node = phys_row[i]
        if cell_node then
          local s_row, s_col = cell_node:start()
          tbl.node_map[('%d,%d'):format(s_row, s_col)] = { r = logical_row.line, c = col_idx }

          local content_node = cell_node:field('contents')[1]
          if content_node then
            local text = vim.treesitter.get_node_text(content_node, bufnr)
            table.insert(cell_lines, vim.trim(text))
          else
            table.insert(cell_lines, '')
          end
          table.insert(cell_nodes, cell_node)
        end
      end

      while #cell_lines > 1 and cell_lines[1] == '' do
        table.remove(cell_lines, 1)
        table.remove(cell_nodes, 1)
      end
      while #cell_lines > 1 and cell_lines[#cell_lines] == '' do
        table.remove(cell_lines)
        table.remove(cell_nodes)
      end

      if span_info.vmerge and #tbl.rows > 0 then
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
          prev_cell.node_to_line = prev_cell.node_to_line or {}

          if span_info.content and vim.trim(span_info.content) ~= '' then
            table.insert(prev_cell.lines, vim.trim(span_info.content))
            if span_info.node then prev_cell.node_to_line[span_info.node:id()] = #prev_cell.lines end
            span_info.content = nil
          end

          for idx_line, ln in ipairs(cell_lines) do
            if vim.trim(ln) ~= '' then
              table.insert(prev_cell.lines, ln)
              if cell_nodes[idx_line] then prev_cell.node_to_line[cell_nodes[idx_line]:id()] = #prev_cell.lines end
            end
          end
          prev_cell:update_display_len()
        end

        local cell =
          TableCell:new({ row_idx = logical_row.line, col_idx = col_idx, colspan = span_info.span, rowspan = 0, lines = {} })
        logical_row:add_cell(cell)
      else
        local cell = TableCell:new({
          row_idx = logical_row.line,
          col_idx = col_idx,
          colspan = span_info.span,
          rowspan = 1,
          lines = cell_lines,
        })
        cell.node_to_line = {}
        for idx_line, n in ipairs(cell_nodes) do
          cell.node_to_line[n:id()] = idx_line
        end
        logical_row:add_cell(cell)
      end

      col_idx = col_idx + span_info.span
    end

    table.insert(tbl.rows, logical_row)
    table.insert(tbl.logical_grid, logical_row)
  end

  local function process_node(child)
    local type = child:type()

    if type == 'row_block' then
      for inner in child:iter_children() do
        process_node(inner)
      end
    elseif type == 'row' then
      local cells = child:field('cell')
      if not has_seen_crown and tbl.col_count < 1 then
        has_seen_crown = true
        tbl.col_count = #cells
      end
      table.insert(current_physical_rows, cells)

      if not is_multi_line_mode then
        commit_logical_row()
        current_physical_rows = {}
      end
    elseif type == 'hr' then
      if is_multi_line_mode then
        pending_hrs = pending_hrs + 1
      else
        commit_logical_row()
        current_physical_rows = {}
        table.insert(tbl.logical_grid, { type = type })
      end
    elseif type == 'cbe' then
      commit_logical_row()
      current_physical_rows = {}

      local current_col_idx = 1
      for _, cell_node in ipairs(child:field('cb_cell')) do
        local s_row, s_col = cell_node:start()
        tbl.node_map[('%d,%d'):format(s_row, s_col)] = { r = math.max(1, #tbl.rows), c = current_col_idx }
        current_col_idx = current_col_idx + 1
      end

      while pending_hrs > 0 do
        table.insert(tbl.logical_grid, { type = 'hr' })
        pending_hrs = pending_hrs - 1
      end

      table.insert(tbl.logical_grid, { type = type })
      is_multi_line_mode = false
      current_top_boundary = nil
    elseif utils.set({ 'cbi', 'cbo' })[type] then
      commit_logical_row()
      current_physical_rows = {}

      while pending_hrs > 0 do
        table.insert(tbl.logical_grid, { type = 'hr' })
        pending_hrs = pending_hrs - 1
      end

      local spans = {}
      local span = 0
      local current_col_idx = 1

      for i, cell_node in ipairs(child:field('cb_cell')) do
        span = span + 1

        local s_row, s_col = cell_node:start()
        local mapped_r = #tbl.rows + 1
        if type == 'cbo' and is_multi_line_mode then mapped_r = math.max(1, #tbl.rows) end
        tbl.node_map[('%d,%d'):format(s_row, s_col)] = { r = mapped_r, c = current_col_idx }

        local corner_node = cell_node:field('cb_corner')[1]

        if corner_node then
          local vmerge = false
          local content = nil

          if type == 'cbi' then
            local content_node = cell_node:field('contents')[1]
            local has_vmerge = corner_node:type() == 'vmerge'

            if content_node then
              vmerge = true
              content = vim.trim(vim.treesitter.get_node_text(content_node, bufnr))
            elseif has_vmerge then
              vmerge = true
            end

            if vmerge and current_top_boundary and current_top_boundary.spans then
              local search_col = 1
              for _, top_span in ipairs(current_top_boundary.spans) do
                if search_col == current_col_idx then
                  span = top_span.span
                  break
                end
                search_col = search_col + top_span.span
              end
            end
          end

          table.insert(spans, { span = span, start = i, vmerge = vmerge, content = content, node = cell_node })
          current_col_idx = current_col_idx + span
          span = 0
        end
      end

      local boundary = { type = type, spans = spans }
      table.insert(tbl.logical_grid, boundary)
      current_top_boundary = boundary

      if type == 'cbo' then is_multi_line_mode = true end
      if not has_seen_crown and #tbl.rows > 0 then has_seen_crown = true end
    end
  end

  for child in node:iter_children() do
    process_node(child)
  end

  commit_logical_row()

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
    self.col_widths[i] = 1
  end

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

  local total = 1
  for i = 1, self.col_count do
    total = total + self.col_widths[i] + 3
  end

  if total > max_table_width then
    local excess = total - max_table_width
    while excess > 0 do
      local largest_idx, largest_val = 1, 0
      for i = 1, self.col_count do
        if self.col_widths[i] > largest_val then
          largest_val, largest_idx = self.col_widths[i], i
        end
      end
      if largest_val <= 1 then break end
      self.col_widths[largest_idx] = self.col_widths[largest_idx] - 1
      excess = excess - 1
    end
  end
end

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
  local cell_positions = {}

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
        available = available + (cell.rowspan - 1)

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

  local cell_line_cursor = {}
  local next_row_idx = 1
  local current_phys_line = 1

  for _, item in ipairs(self.logical_grid) do
    if item.type == 'hr' or item.type == 'cbo' or item.type == 'cbi' or item.type == 'cbe' then
      local chars = { hr = '=', cbo = '-', cbi = '~', cbe = '-' }
      local fill = chars[item.type] or '-'

      local line_char = '+'
      if item.type == 'cbo' then
        line_char = 'v'
      elseif item.type == 'cbe' then
        line_char = '^'
      end

      local line = line_char

      if not item.spans then
        for i = 1, self.col_count do
          line = line .. string.rep(fill, self.col_widths[i] + 2) .. line_char
        end
      else
        local col_idx = 1
        for _, span_info in ipairs(item.spans) do
          if span_info.vmerge then
            local active_cell = nil
            for _, r in ipairs(self.rows) do
              for _, c in ipairs(r.cells) do
                if c.col_idx == col_idx and c.rowspan > 0 then
                  if c.row_idx < next_row_idx and (c.row_idx + c.rowspan - 1) >= next_row_idx then
                    active_cell = c
                    break
                  end
                end
              end
              if active_cell then break end
            end

            local text = ''
            if active_cell then
              local line_idx = cell_line_cursor[active_cell] or 1
              text = active_cell.wrapped[line_idx] or ''
              cell_line_cursor[active_cell] = line_idx + 1
            end

            local total_chars = 0
            for i = 0, span_info.span - 1 do
              total_chars = total_chars + self.col_widths[col_idx + i] + 2
            end
            total_chars = total_chars + span_info.span

            local text_w = vim.api.nvim_strwidth(text)
            local pad_len = total_chars - text_w - 3
            if pad_len < 0 then pad_len = 0 end

            line = line .. ' ' .. text .. string.rep(' ', pad_len) .. ' ' .. line_char
          else
            local span_str = ''
            for i = 0, span_info.span - 1 do
              local c = col_idx + i
              local w = self.col_widths[c] + 2
              span_str = span_str .. string.rep(fill, w)
              if i < span_info.span - 1 then span_str = span_str .. '*' end
            end
            span_str = span_str .. line_char
            line = line .. span_str
          end
          col_idx = col_idx + span_info.span
        end
      end
      table.insert(rendered_lines, line)
      current_phys_line = current_phys_line + 1
    else
      local logical_row = item
      local row_idx = logical_row.line
      next_row_idx = row_idx + 1
      local phys_count = row_phys_lines[row_idx] or 1

      for l = 1, phys_count do
        local line_str = '|'
        local col_idx = 1

        while col_idx <= self.col_count do
          local active_cell = nil
          for _, c in ipairs(logical_row.cells) do
            if c.col_idx == col_idx then
              active_cell = c
              break
            end
          end

          if active_cell and active_cell.rowspan == 0 then
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

          if l == 1 and active_cell and active_cell.row_idx == row_idx then
            cell_positions[active_cell] = { line = current_phys_line, col = #line_str + 1 }
          end

          local text = ''
          if active_cell then
            local line_idx = cell_line_cursor[active_cell] or 1
            text = active_cell.wrapped[line_idx] or ''
            cell_line_cursor[active_cell] = line_idx + 1
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
        current_phys_line = current_phys_line + 1
      end
    end
  end

  return rendered_lines, cell_positions
end

function Table:reformat(track_r, track_c)
  if not self.node then return false end
  local start_line, start_col = self.node:range()
  local bufnr = vim.api.nvim_get_current_buf()

  local target_indent = indent.indentexpr(start_line + 1, bufnr)
  local indent_pad = string.rep(' ', target_indent)

  local lines, cell_positions = self:draw()
  local contents = vim.tbl_map(function(line) return ('%s%s'):format(indent_pad, line) end, lines)

  local target_cell = nil
  if track_r and track_c then
    for r_idx = track_r, 1, -1 do
      for _, cl in ipairs(self.rows[r_idx].cells) do
        if cl.col_idx <= track_c and (cl.col_idx + cl.colspan - 1) >= track_c then
          if cl.rowspan > 0 then
            target_cell = cl
            break
          end
        end
      end
      if target_cell then break end
    end
  end

  local view = vim.fn.winsaveview() or {}
  vim.api.nvim_buf_set_lines(0, self.range.start_line - 1, self.range.end_line, false, contents)

  if target_cell and cell_positions[target_cell] then
    view.lnum = self.range.start_line - 1 + cell_positions[target_cell].line
    view.col = start_col + cell_positions[target_cell].col
    view.coladd = 0
  end

  vim.fn.winrestview(view)
  return true
end

function Table:sync_boundaries()
  if #self.rows > 0 then
    local first_row_complex = false
    for _, cell in ipairs(self.rows[1].cells) do
      if cell.colspan > 1 or cell.rowspan > 1 or cell.rowspan == 0 or #cell.lines > 1 then
        first_row_complex = true
        break
      end
    end

    if first_row_complex then
      local new_row = TableRow:new({ table = self, line = 1 })
      for c = 1, self.col_count do
        new_row:add_cell(TableCell:new({ row_idx = 1, col_idx = c, colspan = 1, rowspan = 1, lines = {} }))
      end
      table.insert(self.rows, 1, new_row)

      for r_idx, r in ipairs(self.rows) do
        r.line = r_idx
        for _, c in ipairs(r.cells) do
          c.row_idx = r_idx
        end
      end
    end
  end

  local old_grid = self.logical_grid
  local has_hr_before_row = {}
  local trailing_hr = false

  local seen_hr = false
  for _, item in ipairs(old_grid) do
    if item.type then
      if item.type == 'hr' then seen_hr = true end
    else
      has_hr_before_row[item] = seen_hr
      seen_hr = false
    end
  end
  if seen_hr then trailing_hr = true end

  local new_grid = {}
  local in_multi = false

  for i, row in ipairs(self.rows) do
    local needs_cbi = false
    local has_complex = false

    for _, cell in ipairs(row.cells) do
      if cell.rowspan == 0 then needs_cbi = true end
      if cell.colspan > 1 or cell.rowspan > 1 or #cell.lines > 1 then has_complex = true end
    end

    local needs_hr = has_hr_before_row[row]

    if needs_hr then
      if in_multi then
        table.insert(new_grid, { type = 'cbe', spans = {} })
        in_multi = false
      end
      table.insert(new_grid, { type = 'hr', spans = {} })
    end

    local needed_boundary = nil
    if needs_cbi then
      needed_boundary = 'cbi'
      in_multi = true
    elseif has_complex then
      if not in_multi then
        needed_boundary = 'cbo'
      else
        needed_boundary = 'cbi'
      end
      in_multi = true
    else
      if in_multi then
        needed_boundary = 'cbe'
        in_multi = false
      end
    end

    if needed_boundary then table.insert(new_grid, { type = needed_boundary, spans = {} }) end
    table.insert(new_grid, row)
  end

  if in_multi then table.insert(new_grid, { type = 'cbe', spans = {} }) end
  if trailing_hr then table.insert(new_grid, { type = 'hr', spans = {} }) end

  for idx, item in ipairs(new_grid) do
    if item.type and item.type ~= 'hr' and item.type ~= 'cbe' then
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
        while col <= self.col_count do
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
        local prev_row = self.rows[#self.rows]
        if prev_row then
          local spans = {}
          local col = 1
          while col <= self.col_count do
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
    else
      if item.type then item.spans = nil end
    end
  end

  self.logical_grid = new_grid
end

function Table:handle_cr()
  local cursor = vim.api.nvim_win_get_cursor(0)

  local tbl = Table.from_current_node(cursor)
  if not tbl then return false end

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

  if not target_node then return false end

  local s_row, s_col = target_node:start()
  local mapped = tbl.node_map[('%d,%d'):format(s_row, s_col)]
  if not mapped then return false end

  local r, c = mapped.r, mapped.c
  local active_cell = nil
  for _, cl in ipairs(tbl.rows[r].cells) do
    if cl.col_idx <= c and (cl.col_idx + cl.colspan - 1) >= c then
      active_cell = cl
      break
    end
  end

  if active_cell and active_cell.rowspan == 0 then
    for root_r = r - 1, 1, -1 do
      for _, root_c in ipairs(tbl.rows[root_r].cells) do
        if
          root_c.col_idx <= active_cell.col_idx
          and (root_c.col_idx + root_c.colspan - 1) >= active_cell.col_idx
          and root_c.rowspan > 0
        then
          active_cell = root_c
          break
        end
      end
      if active_cell and active_cell.rowspan > 0 then break end
    end
  end

  if not active_cell then return false end

  local bufnr = vim.api.nvim_get_current_buf()
  local content_node = target_node:field('contents')[1]

  local prefix, suffix, target_text = '', '', ''

  if content_node then
    local cs_row, cs_col, ce_row, ce_col = content_node:range()
    local cursor_col = cursor[2]

    local text = vim.treesitter.get_node_text(content_node, bufnr)
    target_text = vim.trim(text)

    local relative_col = cursor_col - cs_col
    if relative_col < 0 then relative_col = 0 end
    if relative_col > #text then relative_col = #text end

    prefix = vim.trim(text:sub(1, relative_col))
    suffix = vim.trim(text:sub(relative_col + 1))
  else
    target_text = ''
    prefix = ''
    suffix = ''
  end

  local target_line_idx = active_cell.node_to_line and active_cell.node_to_line[target_node:id()]

  local replaced = false
  local new_lines = {}

  if target_line_idx then
    for i, line_text in ipairs(active_cell.lines) do
      if not replaced and i == target_line_idx then
        table.insert(new_lines, prefix)
        table.insert(new_lines, suffix)
        replaced = true
      else
        table.insert(new_lines, line_text)
      end
    end
  else
    for i, line_text in ipairs(active_cell.lines) do
      if not replaced and line_text == target_text then
        table.insert(new_lines, prefix)
        table.insert(new_lines, suffix)
        target_line_idx = i
        replaced = true
      else
        table.insert(new_lines, line_text)
      end
    end
  end

  if not replaced then
    if #active_cell.lines == 0 then
      table.insert(new_lines, '')
      table.insert(new_lines, '')
      target_line_idx = 1
    else
      table.insert(new_lines, suffix)
      target_line_idx = #active_cell.lines
    end
  end

  active_cell.lines = new_lines

  while #active_cell.lines > 1 and active_cell.lines[1] == '' do
    table.remove(active_cell.lines, 1)
    target_line_idx = math.max(1, target_line_idx - 1)
  end
  while #active_cell.lines > 1 and active_cell.lines[#active_cell.lines] == '' do
    table.remove(active_cell.lines)
  end

  if active_cell.update_display_len then active_cell:update_display_len() end

  if tbl.sync_boundaries then tbl:sync_boundaries() end

  local _, cell_positions = tbl:draw()

  tbl:reformat()

  local c_pos = cell_positions[active_cell]
  if c_pos then
    local max_w = 0
    for c_idx = active_cell.col_idx, active_cell.col_idx + active_cell.colspan - 1 do
      max_w = max_w + tbl.col_widths[c_idx]
    end
    max_w = max_w + (active_cell.colspan - 1) * 3

    local prefix_lines = {}
    for i = 1, target_line_idx do
      table.insert(prefix_lines, active_cell.lines[i])
    end

    local prefix_wrapped = wrap_lines(prefix_lines, max_w)
    local lines_down = #prefix_wrapped

    local target_line = tbl.range.start_line - 1 + c_pos.line + lines_down
    local _, start_col = tbl.node:range()
    local target_col = start_col + c_pos.col

    vim.api.nvim_win_set_cursor(0, { target_line, target_col })
  end

  return true
end

return Table
