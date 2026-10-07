local Table = require('fey.files.elements.table')

local function format_line(linenr)
  local tbl = Table.from_current_node({ linenr, 0 })
  if tbl and tbl:reformat() then
    return true
  end

  -- a clock tag whose start or end was edited gets its time written again
  local Logbook = require('fey.files.elements.logbook')
  local line = vim.api.nvim_buf_get_lines(0, linenr - 1, linenr, false)[1]
  if line and Logbook.is_clock_line(line) then
    Logbook.recalculate_line(0, linenr)
    return true
  end

  return false
end

local formatexpr_cache = {}

local function format()
  if vim.tbl_contains({ 'i', 'R', 'ic', 'ix' }, vim.fn.mode()) then
    -- `formatexpr` is also called when exceeding `textwidth` in insert mode
    -- fall back to internal formatting
    return 1
  end

  local start_line = vim.v.lnum
  local end_line = vim.v.lnum + vim.v.count - 1
  local formatted = false

  -- If single line is being formatted and is cached in the loop below,
  -- Just fallback to internal formatting
  if start_line == end_line and formatexpr_cache[start_line] then
    return 1
  end

  -- When closed folds are being formatted, fallback formatting can
  -- happen with multiple lines instead of a single line due to some side effects.
  -- When we encounter that we need to return 0 to avoid infinite loop.
  -- This will prevent some of the lines of being formatted correctly,
  -- but there's no way to exit the infinite loop otherwise.
  for linenr = start_line, end_line do
    if formatexpr_cache[linenr] and vim.fn.foldclosed(linenr) > -1 then
      return 0
    end
  end

  for linenr = start_line, end_line do
    local line_formatted = format_line(linenr)
    if not line_formatted then
      formatexpr_cache[linenr] = true
    end
    formatted = formatted or line_formatted
  end

  for line in pairs(formatexpr_cache) do
    vim.cmd(('%dnormal! gqq'):format(line))
  end

  formatexpr_cache = {}

  return formatted and 0 or 1
end

return format
