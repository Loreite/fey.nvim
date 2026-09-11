local M = {}

local sequences = require('fey.sequences')

local function get_heading_depth(node, buf)
  if not node then
    return 0
  end
  local prefix_node = node:field('prefix')[1]
  if not prefix_node then
    return 0
  end

  local text = vim.treesitter.get_node_text(prefix_node, buf)
  local _, count = text:gsub('[.,:;/\\!?\'"%-+*=@&#$%%]', '')
  return count
end

---@param prefix_str string
---@return string leading_space, table tokens
local function parse_prefix_tokens(prefix_str)
  local leading_space = prefix_str:match('^(%s*)') or ''
  local body = prefix_str:match('^%s*(.-)%s*$') or ''

  local tokens = {}
  for symbol, delim in body:gmatch('([%w_<>{}()%[%]]*)([.:;/\\!?%-+*=@&#$%%])') do
    table.insert(tokens, { symbol = symbol, delim = delim })
  end
  return leading_space, tokens
end

---@param leading_space string
---@param tokens table
---@return string
local function assemble_prefix(leading_space, tokens)
  local result = leading_space
  for _, item in ipairs(tokens) do
    result = result .. item.symbol .. item.delim
  end
  return result
end

---@param buf integer
---@param line integer 0-indexed line number
---@return TSNode|nil heading_node, string|nil prefix_text, table|nil prefix_range
local function get_heading_at_line(buf, line)
  local parser = vim.treesitter.get_parser(buf, 'fey')
  if not parser then
    return nil
  end
  local tree = parser:parse()[1]
  if not tree then
    return nil
  end

  local root = tree:root()
  local query = vim.treesitter.query.parse(
    'fey',
    [[
    (heading
      prefix: (heading_prefix) @prefix) @heading
  ]]
  )

  for id, node, _ in query:iter_captures(root, buf, line, line + 1) do
    local capture_name = query.captures[id]
    if capture_name == 'heading' then
      local start_row, _, end_row, _ = node:range()
      if start_row <= line and line <= end_row then
        for child in node:iter_children() do
          if child:type() == 'heading_prefix' then
            local p_srow, p_scol, p_erow, p_ecol = child:range()
            local text = vim.api.nvim_buf_get_text(buf, p_srow, p_scol, p_erow, p_ecol, {})[1]
            return node, text, { srow = p_srow, scol = p_scol, erow = p_erow, ecol = p_ecol }
          end
        end
      end
    end
  end
  return nil
end

---@param buf integer
---@param heading_node TSNode
---@return integer start_line, integer end_line
local function get_subtree_range(buf, heading_node)
  local start_row = heading_node:range()
  local root = heading_node:tree():root()
  local current_depth = get_heading_depth(heading_node, buf)

  local total_lines = vim.api.nvim_buf_line_count(buf)
  local end_row = total_lines - 1

  local query = vim.treesitter.query.parse('fey', [[ (heading) @heading ]])
  for _, node, _ in query:iter_captures(root, buf, start_row + 1, total_lines) do
    local r = node:range()

    if r > start_row then
      local depth = get_heading_depth(node, buf)

      if depth > 0 and depth <= current_depth then
        end_row = r - 1
        break
      end
    end
  end

  return start_row, end_row
end

---@param buf integer
---@param target_depth integer
---@return table|nil sample_token
local function find_heading_style_at_depth(buf, target_depth)
  local parser = vim.treesitter.get_parser(buf, 'fey')
  if not parser then
    return nil
  end

  local root = parser:parse()[1]:root()
  local query = vim.treesitter.query.parse('fey', [[ (heading_prefix) @prefix ]])

  for _, node, _ in query:iter_captures(root, buf, 0, -1) do
    local srow, scol, erow, ecol = node:range()
    local text = vim.api.nvim_buf_get_text(buf, srow, scol, erow, ecol, {})[1]
    local _, tokens = parse_prefix_tokens(text)
    if #tokens >= target_depth and tokens[target_depth].symbol ~= '' then
      return tokens[target_depth]
    end
  end

  return nil
end

---@param buf integer
---@param start_line? integer
---@param end_line? integer
function M.reindex_buffer(buf, start_line, end_line)
  buf = buf or vim.api.nvim_get_current_buf()
  local parser = vim.treesitter.get_parser(buf, 'fey')
  if not parser then
    return
  end

  parser:parse(true)
  local root = parser:parse()[1]:root()
  local query = vim.treesitter.query.parse('fey', [[ (heading_prefix) @prefix ]])

  local counters = {}
  local edits = {}
  local firsts = {}

  for _, node, _ in query:iter_captures(root, buf, 0, -1) do
    local srow, scol, erow, ecol = node:range()
    if not (start_line and srow < start_line) and not (end_line and srow > end_line) then
      local prefix_text = vim.api.nvim_buf_get_text(buf, srow, scol, erow, ecol, {})[1]
      local leading_space, tokens = parse_prefix_tokens(prefix_text)
      local depth = #tokens

      if depth > 0 then
        for d = depth + 1, #counters do
          counters[d] = nil
        end

        -- Only increment sequence count if the leaf level token is not anonymous/empty
        if tokens[depth] and tokens[depth].symbol ~= '' then
          counters[depth] = (counters[depth] or 0) + 1
        end

        for d = 1, depth do
          local item = tokens[d]
          if item and item.symbol ~= '' then
            local pattern_key = firsts[d]
            if not pattern_key then
              pattern_key = sequences.detect_pattern(item.symbol)
              firsts[d] = pattern_key
            end
            local pattern = sequences.patterns[pattern_key]
            if pattern and pattern.to_symbol then
              local idx = (d == depth) and counters[depth] or (counters[d] or 1)
              item.symbol = pattern.to_symbol(idx)
            end
            -- else
            --   -- Blank at this depth resets what "first" means for it
            --   firsts[d] = nil
          end
        end

        local new_prefix = assemble_prefix(leading_space, tokens)
        if new_prefix ~= prefix_text then
          table.insert(edits, { srow = srow, scol = scol, erow = erow, ecol = ecol, text = new_prefix })
        end
      end
    end
  end

  for i = #edits, 1, -1 do
    local ed = edits[i]
    vim.api.nvim_buf_set_text(buf, ed.srow, ed.scol, ed.erow, ed.ecol, { ed.text })
  end
end

--- Promotes (decreases depth) or Demotes (increases depth) the current heading
---@param direction "promote"|"demote"
function M.change_depth(direction)
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = cursor[1] - 1

  local node, prefix_text, range = get_heading_at_line(buf, line)
  if not node or not range or not prefix_text then
    return
  end

  local leading_space, tokens = parse_prefix_tokens(prefix_text)
  local current_depth = #tokens

  if direction == 'demote' then
    local target_depth = current_depth + 1
    local style = find_heading_style_at_depth(buf, target_depth)

    local new_symbol = style and style.symbol or 'a'
    local new_delim = style and style.delim or '.'

    table.insert(tokens, {
      symbol = sequences.increment_symbol(new_symbol, 0),
      delim = new_delim,
    })
  elseif direction == 'promote' then
    if current_depth <= 1 then
      return
    end
    table.remove(tokens)
  end

  local new_prefix = assemble_prefix(leading_space, tokens)
  vim.api.nvim_buf_set_text(buf, range.srow, range.scol, range.erow, range.ecol, { new_prefix })

  M.reindex_buffer(buf)
end

--- Moves a subtree strictly within its sibling bounds at the same hierarchy level
---@param direction "up"|"down"
function M.move_subtree(direction)
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = cursor[1] - 1

  local node, _, _ = get_heading_at_line(buf, line)
  if not node then
    return
  end

  local start_row, end_row = get_subtree_range(buf, node)
  local current_depth = get_heading_depth(node, buf)
  local subtree_lines = vim.api.nvim_buf_get_lines(buf, start_row, end_row + 1, false)

  local parser = vim.treesitter.get_parser(buf, 'fey')
  if not parser then
    return
  end
  local root = parser:parse()[1]:root()
  local query = vim.treesitter.query.parse('fey', [[ (heading) @heading ]])

  if direction == 'up' then
    if start_row == 0 then
      return
    end

    local prev_node = nil
    for _, n, _ in query:iter_captures(root, buf, 0, start_row) do
      local depth = get_heading_depth(n, buf)

      if depth < current_depth then
        prev_node = nil
      elseif depth == current_depth then
        prev_node = n
      end
    end

    if not prev_node then
      return
    end
    local prev_start, _ = get_subtree_range(buf, prev_node)

    local prev_lines = vim.api.nvim_buf_get_lines(buf, prev_start, start_row, false)
    vim.api.nvim_buf_set_lines(buf, prev_start, end_row + 1, false, vim.list_extend(subtree_lines, prev_lines))

    local new_cursor_line = prev_start + (cursor[1] - 1 - start_row)
    vim.api.nvim_win_set_cursor(0, { new_cursor_line + 1, cursor[2] })

  --
  elseif direction == 'down' then
    local total_lines = vim.api.nvim_buf_line_count(buf)
    if end_row >= total_lines - 1 then
      return
    end

    local next_node = nil
    for _, n, _ in query:iter_captures(root, buf, end_row + 1, total_lines) do
      local depth = get_heading_depth(n, buf)
      if depth < current_depth then
        break
      elseif depth == current_depth then
        next_node = n
        break
      end
    end

    if not next_node then
      return
    end
    local _, next_end = get_subtree_range(buf, next_node)
    local block_to_swap_lines = vim.api.nvim_buf_get_lines(buf, end_row + 1, next_end + 1, false)
    local cursor_offset = (cursor[1] - 1) - start_row
    local target_root_line = start_row + #block_to_swap_lines + 1
    vim.api.nvim_buf_set_lines(buf, start_row, next_end + 1, false, vim.list_extend(block_to_swap_lines, subtree_lines))
    vim.api.nvim_win_set_cursor(0, { target_root_line + cursor_offset, cursor[2] })
  end

  M.reindex_buffer(buf)
end

---@param direction "promote"|"demote"
function M.change_subtree_depth(direction)
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = cursor[1] - 1

  local node, _, _ = get_heading_at_line(buf, line)
  if not node then
    return
  end

  local start_row, end_row = get_subtree_range(buf, node)
  local parser = vim.treesitter.get_parser(buf, 'fey')
  if not parser then
    return
  end
  local root = parser:parse()[1]:root()
  local query = vim.treesitter.query.parse('fey', [[ (heading_prefix) @prefix ]])

  local edits = {}
  for _, p_node, _ in query:iter_captures(root, buf, start_row, end_row + 1) do
    local srow, scol, erow, ecol = p_node:range()
    local prefix_text = vim.api.nvim_buf_get_text(buf, srow, scol, erow, ecol, {})[1]
    local leading_space, tokens = parse_prefix_tokens(prefix_text)

    if direction == 'demote' then
      local style = find_heading_style_at_depth(buf, #tokens + 1)
      table.insert(tokens, {
        symbol = style and style.symbol or 'a',
        delim = style and style.delim or '.',
      })
    elseif direction == 'promote' then
      if #tokens > 1 then
        table.remove(tokens)
      end
    end

    local new_prefix = assemble_prefix(leading_space, tokens)
    if new_prefix ~= prefix_text then
      table.insert(edits, { srow = srow, scol = scol, erow = erow, ecol = ecol, text = new_prefix })
    end
  end

  for i = #edits, 1, -1 do
    local ed = edits[i]
    vim.api.nvim_buf_set_text(buf, ed.srow, ed.scol, ed.erow, ed.ecol, { ed.text })
  end

  M.reindex_buffer(buf)
end

function M.setup()
  vim.api.nvim_create_autocmd('FileType', {
    pattern = 'fey',
    callback = function(args)
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(args.buf) then
          pcall(vim.treesitter.start, args.buf, 'fey')
        end
      end)

      local opts = { buffer = args.buf, silent = true }

      vim.keymap.set('n', '<leader>;j', function()
        M.move_subtree('down')
      end, opts)
      vim.keymap.set('n', '<leader>;k', function()
        M.move_subtree('up')
      end, opts)

      vim.keymap.set('n', '<leader>;H', function()
        M.change_subtree_depth('promote')
      end, opts)
      vim.keymap.set('n', '<leader>;L', function()
        M.change_subtree_depth('demote')
      end, opts)

      vim.keymap.set('n', '<leader>;h', function()
        M.change_depth('promote')
      end, opts)
      vim.keymap.set('n', '<leader>;l', function()
        M.change_depth('demote')
      end, opts)

      local augroup = vim.api.nvim_create_augroup('FeyAutoReindex_' .. args.buf, { clear = true })
      local reindex_pending = {}

      local function do_reindex(buf)
        if not vim.api.nvim_buf_is_valid(buf) then
          return
        end
        local save_ei = vim.o.eventignore
        vim.o.eventignore = 'TextChanged,TextChangedI'
        pcall(vim.cmd, 'undojoin')
        pcall(M.reindex_buffer, buf)
        vim.o.eventignore = save_ei
      end

      local function schedule_reindex(buf)
        if reindex_pending[buf] then
          return
        end
        reindex_pending[buf] = true
        vim.schedule(function()
          reindex_pending[buf] = nil
          do_reindex(buf)
        end)
      end

      vim.api.nvim_create_autocmd({ 'InsertLeave', 'TextChanged' }, {
        group = augroup,
        buffer = args.buf,
        callback = function()
          schedule_reindex(args.buf)
        end,
      })

      vim.api.nvim_create_autocmd('BufWritePre', {
        group = augroup,
        buffer = args.buf,
        callback = function()
          reindex_pending[args.buf] = nil
          do_reindex(args.buf)
        end,
      })
    end,
  })
end

vim.treesitter.query.add_predicate('fey-is-heading-level?', function(match, _, source, predicate)
  if type(source) == 'number' and not vim.api.nvim_buf_is_loaded(source) then
    return false
  end
  local node = match[predicate[2]]
  node = node and node[#node]
  if not node then
    return false
  end

  local target_level = tonumber(predicate[3])
  local text = vim.treesitter.get_node_text(node, source)
  local _, count = text:gsub('[.,:;/\\!?\'"%-+*=@&#$%%]', '')

  return ((count - 1) % 8) + 1 == target_level
end, { force = true, all = true })

return M
