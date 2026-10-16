-- Table formulas and settings: the tags (`fey_tblfm_tag_name`, `tblfm`) that follow a table with no blank line between.
--
--   | qty | price | total |
--   +=====+=======+=======+
--   | 2   | 3.5   |       |
--   | 4   | 1.25  |       |
--   {# tblfm; tblwidth: 80; total: qty * price #}
--
-- Every key of the head is a setting when it names one (`tblwidth`) and a formula otherwise: the key is the target, the
-- value the expression, in the language of the query tag (`fey.query`), so a table, a database view and a query
-- share one language. The formulas run in the order they are written, each one sees the results of those before it.
-- Several tags one after the other are one: a table can have its settings and its formulas in separate tags.
--
-- Targets (a key is a word: letters, digits and `_`):
--   total              every cell of the column `total` (the text of its header, lower case, other characters as `_`)
--   c3                 every cell of the third column
--   r3                 every cell of the third row
--   r3c4               one cell
--   r2to4c3            the cells of the rows 2 to 4 of the third column; `last` is the last row (`r2tolast_total`)
--   r2to4_total        the same, the column by the name of its header
-- Rows are counted after the header (the rows above the first rule row); with no rule row, every row is a row.
--
-- What an expression sees: the cells of its row by the name of the column (and `c1`, `c2`, ...), `n` (its row), `c` (its
-- column), `rows` (every row, an object like the first), `above`, `below` and `column` (the values of its column), and
-- `note` (the properties of the note). A cell is a number when it reads as one, a date when it reads as one, and text
-- otherwise; an empty cell is null.
--
-- The result is written into the cell as the result of a `query` tag is written below it: the formula stays, the value is
-- the result. A formula that fails leaves its cell as it is, and is told to the caller.
local V = require('fey.query.values')
local ops = require('fey.query.ops')
local parser = require('fey.query.parser')
local eval = require('fey.query.eval')

local M = {}

local NULL = V.NULL

---The settings a key may name, and what a value must be
---@type table<string, fun(value: string): any, string|nil>
M.settings = {
  tblwidth = function(value)
    local n = tonumber(value)
    if not n or n < 1 or n % 1 ~= 0 then return nil, 'tblwidth is a whole number of columns, like 80' end
    return n
  end,
}

---The translation of the functions of the Emacs calc that have a name here
local CALC_FUNCTIONS = { vsum = 'sum', vmean = 'average', vmax = 'max', vmin = 'min', vcount = 'length' }

---@param tbl FeyTable
---@param tag FeyTag
---@param source integer|string
function M.read_tag(tbl, tag, source)
  if tag.node:has_error() then
    tbl.errors[#tbl.errors + 1] = 'a tag under the table has a syntax error (a value of the head may not hold , or ;: write the formula in the body)'
    return
  end
  for _, key in ipairs(tag.key_order or {}) do
    M.add(tbl, key, tag.key_values[key])
  end
  -- the body of a scope tag is what it applies to (the table), not words of its own
  if tag.body and tag.type ~= 'scope_tag' then
    local var_opts = type(source) == 'number' and { bufnr = source } or { src = source }
    local body = require('fey.vars').interpolate(vim.trim(vim.treesitter.get_node_text(tag.body, source)), var_opts)
    -- one formula to a line, or after the other with `::` as the old tables were written: `$3=$1*$2::$4=$1+$2`
    for piece in (body:gsub('\n', '::') .. '::'):gmatch('(.-)::') do
      piece = vim.trim(piece)
      if piece ~= '' then
        local target, expr = piece:match('^([^=:]-)%s*[=:]%s*(.+)$')
        if not target then
          tbl.errors[#tbl.errors + 1] = ('formula not understood: %s'):format(piece)
        else
          expr = expr:gsub(';[^;)]*$', '') -- the format of the calc
          expr = expr:gsub('%$(%d+)', 'c%1'):gsub('(%a+)%(', function(fn) return (CALC_FUNCTIONS[fn] or fn) .. '(' end)
          local col = target:match('^%$(%d+)$')
          M.add(tbl, col and ('c' .. col) or vim.trim(target), vim.trim(expr))
        end
      end
    end
  end
end

---@param tbl FeyTable
---@param key string
---@param value string
function M.add(tbl, key, value)
  local setting = M.settings[key:lower()]
  if setting then
    local v, err = setting(value or '')
    if v == nil then
      tbl.errors[#tbl.errors + 1] = err
    else
      tbl.config[key:lower()] = v
    end
    return
  end
  tbl.formulas[#tbl.formulas + 1] = { target = key, expr = value or '' }
end

-- The cells ------------------------------------------------------------------------------------------------------------

---@param text string
---@return string
local function name_of(text) return (vim.trim(text):lower():gsub('[^%w]+', '_'):gsub('^_+', ''):gsub('_+$', '')) end

---@param text string
---@return any
local function parse_value(text)
  text = vim.trim(text)
  if text == '' then return NULL end
  local n = tonumber(text)
  if n and not text:find('^0[xX]') then return n end
  if text == 'true' then return true end
  if text == 'false' then return false end
  if text:match('^%d%d%d%d%-%d%d%-%d%d') then
    local d = V.parse_date(text)
    if d then return d end
  end
  return text
end

---@param tbl FeyTable
---@return table grid { head: FeyTableRow[], body: FeyTableRow[], names: string[], index: table<string, integer> }
local function layout(tbl)
  local has_rule = false
  for _, item in ipairs(tbl.logical_grid) do
    if item.type == 'hr' then has_rule = true end
  end
  local head, body, seen = {}, {}, false
  for _, item in ipairs(tbl.logical_grid) do
    if item.type == 'hr' then
      seen = true
    elseif not item.type then
      if has_rule and not seen then head[#head + 1] = item else body[#body + 1] = item end
    end
  end
  local names, index = {}, {}
  if head[1] then
    for _, cell in ipairs(head[1].cells) do
      local name = name_of(table.concat(cell.lines, ' '))
      if name ~= '' and not index[name] then
        index[name] = cell.col_idx
        names[cell.col_idx] = name
      end
    end
  end
  return { head = head, body = body, names = names, index = index }
end

---The cell of a row that covers a column, and the cell that holds its text (a merged cell lives in the row it starts)
---@param tbl FeyTable
---@param grid table
---@param r integer
---@param c integer
---@return FeyTableCell|nil cell the cell to write, or nil when the column is covered by a wider cell
local function cell_at(tbl, grid, r, c)
  local row = grid.body[r]
  if not row then return nil end
  for _, cell in ipairs(row.cells) do
    if cell.col_idx == c then return cell end
  end
  return nil
end

---@param cell FeyTableCell|nil
---@return string
local function text_of(cell)
  if not cell then return '' end
  return vim.trim(table.concat(cell.lines, ' '))
end

---The properties of the note the table is in, when the note is in a vault
---@param source integer|string
---@return table
local function note_object(source)
  if type(source) ~= 'number' then return V.object({}) end
  local path = vim.api.nvim_buf_get_name(source)
  local vault = path ~= '' and require('fey.vault').for_path(path)
  if not vault then return V.object({}) end
  local rel = vault:rel_of(path)
  local row = rel and vault:query('SELECT data FROM files WHERE path = :p', { p = rel })[1]
  if not row or not row.data then return V.object({}) end
  local ok, data = pcall(vim.json.decode, row.data)
  local obj = ok and V.from_json(data, true)
  return V.is_object(obj) and obj or V.object({})
end

-- Targets --------------------------------------------------------------------------------------------------------------

---@param grid table
---@param ncols integer
---@param spec string
---@return { r: integer, c: integer }[]|nil cells, in the order they are computed
---@return string|nil err
local function resolve(grid, ncols, spec)
  local nrows = #grid.body
  local key = spec:lower()

  local function column(name)
    if grid.index[name] then return grid.index[name] end
    local n = name:match('^c(%d+)$')
    n = n and tonumber(n)
    if n and n >= 1 and n <= ncols then return n end
    return nil
  end
  local function row_number(text)
    if text == 'last' then return nrows end
    return tonumber(text)
  end

  -- a column: all its rows
  local col = column(key)
  if col then
    local out = {}
    for r = 1, nrows do
      out[#out + 1] = { r = r, c = col }
    end
    return out
  end

  -- r3, r3c4, r2to4c3, r2tolast_total: rows, and a column or all of them
  local a, rest = key:match('^r(%d+)(.*)$')
  if not a then a, rest = key:match('^r(last)(.*)$') end
  if not a then return nil, ('no such column or row: %s'):format(spec) end
  local b, tail = rest:match('^to(%d+)(.*)$')
  if not b then
    b, tail = rest:match('^to(last)(.*)$')
  end
  tail = b and tail or rest
  local from, to = row_number(a), row_number(b or a)
  if not from or not to or from < 1 or to < from or to > nrows then
    return nil, ('no such row in the target %s (the table has %d)'):format(spec, nrows)
  end

  local cols = {}
  local n = tail:match('^c(%d+)$')
  if tail == '' then
    for c = 1, ncols do
      cols[#cols + 1] = c
    end
  elseif n then
    cols[1] = tonumber(n)
  elseif tail:sub(1, 1) == '_' and grid.index[tail:sub(2)] then
    cols[1] = grid.index[tail:sub(2)]
  end
  if #cols == 0 or cols[1] < 1 or cols[#cols] > ncols then return nil, ('no such column in the target %s'):format(spec) end
  local out = {}
  for r = from, to do
    for _, c in ipairs(cols) do
      out[#out + 1] = { r = r, c = c }
    end
  end
  return out
end

-- Applying --------------------------------------------------------------------------------------------------------------

---Compute the formulas of the table and write the results into its cells
---@param tbl FeyTable
---@param source integer|string the buffer, or the text, the table is from
---@return integer changed how many cells got another text
---@return string[] errors
function M.apply(tbl, source)
  local errors = vim.list_extend({}, tbl.errors)
  if #tbl.formulas == 0 then return 0, errors end

  local grid = layout(tbl)
  local ncols = tbl.col_count
  local note = note_object(source)

  -- the values of the body, kept up to date as the formulas write
  local values = {}
  for r, row in ipairs(grid.body) do
    values[r] = {}
    for c = 1, ncols do
      values[r][c] = parse_value(text_of(cell_at(tbl, grid, r, c)))
    end
    for _, cell in ipairs(row.cells) do
      -- a cell that covers columns is the value of each of them
      for c = cell.col_idx + 1, cell.col_idx + cell.colspan - 1 do
        values[r][c] = values[r][cell.col_idx]
      end
    end
  end

  local row_objects = {}
  local function row_object(r)
    if row_objects[r] then return row_objects[r] end
    local obj = V.object({})
    for c = 1, ncols do
      local v = values[r][c]
      obj['c' .. c] = v
      if grid.names[c] then obj[grid.names[c]] = v end
    end
    row_objects[r] = obj
    return obj
  end
  local function rows_list()
    local out = {}
    for r = 1, #grid.body do
      out[r] = row_object(r)
    end
    return V.list(out)
  end

  local function column_values(c, from, to)
    local out = {}
    for r = from, to do
      local v = values[r][c]
      if v ~= NULL then out[#out + 1] = v end
    end
    return V.list(out)
  end

  local changed = 0
  for _, f in ipairs(tbl.formulas) do
    local targets, err = resolve(grid, ncols, f.target)
    if not targets then
      errors[#errors + 1] = err
    else
      local ok, ast = pcall(parser.parse_expression, f.expr)
      local fn = ok and select(2, pcall(eval.compile, ast))
      if not ok or type(fn) ~= 'function' then
        errors[#errors + 1] = ('%s: %s'):format(f.target, tostring(ok and fn or ast):gsub('^query: ', ''))
      else
        for _, t in ipairs(targets) do
          local cell = cell_at(tbl, grid, t.r, t.c)
          if cell then
            local env = eval.new_env(row_object(t.r), note)
            env.scope = {
              n = t.r,
              c = t.c,
              rows = rows_list(),
              above = column_values(t.c, 1, t.r - 1),
              below = column_values(t.c, t.r + 1, #grid.body),
              column = column_values(t.c, 1, #grid.body),
              note = note,
            }
            local good, result = pcall(fn, env)
            if not good then
              errors[#errors + 1] = ('%s: %s'):format(f.target, tostring(result):gsub('^query: ', ''))
            elseif V.is_null(result) then
              -- a property of the note that is not there, a cell nothing is in: the cell keeps what it had
              errors[#errors + 1] = ('%s: the result is empty'):format(f.target)
            elseif type(result) == 'number' and (result ~= result or math.abs(result) == math.huge) then
              errors[#errors + 1] = ('%s: the result is not a number'):format(f.target)
            else
              local text = ops.tostring(result)
              if text ~= text_of(cell) then
                cell.lines = { text }
                cell:update_display_len()
                changed = changed + 1
              end
              values[t.r][t.c] = parse_value(text)
              row_objects[t.r] = nil
            end
          end
        end
      end
    end
  end
  return changed, errors
end

return M
