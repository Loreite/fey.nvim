-- Tables: the alignment of the columns, the width of a table, rows broken over lines, and the formulas. Run from the repo root:
--
--   FEY_PARSER=/path/to/fey.so nvim --headless --clean -l tests/table.lua
vim.opt.rtp:prepend('.')
if vim.env.FEY_PARSER then vim.treesitter.language.add('fey', { path = vim.env.FEY_PARSER }) end
require('fey').setup({ fey_court_dir = vim.fn.tempname() .. '/court' })
local Table = require('fey.files.elements.table')
local ops = require('fey.files.elements.table.operations')
local formula = require('fey.files.elements.table.formula')

vim.notify = function() end
local failures, total = 0, 0
local function check(name, got, want)
  total = total + 1
  if not vim.deep_equal(got, want) then
    failures = failures + 1
    print(('FAIL %s\n  got:  %s\n  want: %s'):format(name, vim.inspect(got), vim.inspect(want)))
  end
end

---A buffer with the lines, the cursor on a line
local function load(lines, row, col)
  vim.cmd('enew!')
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  vim.bo.filetype = 'fey'
  vim.treesitter.start(0, 'fey')
  vim.api.nvim_win_set_cursor(0, { row or 3, col or 2 })
end
local function lines() return vim.api.nvim_buf_get_lines(0, 0, -1, false) end
local function current() return Table.from_current_node() end
---The text of a cell: its lines joined
local function cell_text(tbl, r, c)
  for _, cell in ipairs(tbl.rows[r].cells) do
    if cell.col_idx == c then return table.concat(cell.lines, ' ') end
  end
end
local function texts(tbl)
  local out = {}
  for r, row in ipairs(tbl.rows) do
    out[r] = {}
    for c = 1, tbl.col_count do
      out[r][c] = cell_text(tbl, r, c) or ''
    end
  end
  return out
end

-- alignment ------------------------------------------------------------------------------------------------------------
load({ '  I. T', '', '| name | qty | note |', '+:=====+====:+:====:+', '| apple | 2 | ok |', '| fig | 10 | late |' }, 3, 2)
local tbl = current()
check('the rule row says the alignment', tbl.align, { 'left', 'right', 'center' })
tbl:reformat()
check('a reformat pads by the alignment', lines(), {
  '  I. T',
  '',
  '| name  | qty | note |',
  '+:======+====:+:====:+',
  '| apple |   2 |  ok  |',
  '| fig   |  10 | late |',
})
check('the table reads the same again', texts(current()), { { 'name', 'qty', 'note' }, { 'apple', '2', 'ok' }, { 'fig', '10', 'late' } })
local before = lines()
current():reformat()
check('a second reformat changes nothing', lines(), before)

load({ '  I. T', '', '| a | b |', '+===+===+', '| 1 | 2 |' }, 3, 2)
current():reformat()
check('no marks, no alignment', current().align, {})
check('and the rule row has none', lines()[4], '+===+===+')

-- the columns keep their alignment when they move ------------------------------------------------------------------------
load({ '  I. T', '', '| a | b | c |', '+:==+==:+:=:+', '| 1 | 2 | 3 |' }, 3, 2)
ops.insert_col_after()
check('a new column has none', current().align, { 'left', false, 'right', 'center' })
load({ '  I. T', '', '| a | b | c |', '+:==+==:+:=:+', '| 1 | 2 | 3 |' }, 3, 2)
ops.move_col_right()
check('a moved column takes its alignment', current().align, { 'right', 'left', 'center' })
load({ '  I. T', '', '| a | b | c |', '+:==+==:+:=:+', '| 1 | 2 | 3 |' }, 3, 2)
ops.delete_col()
check('a deleted column takes its alignment', current().align, { 'right', 'center' })

-- the width of a table ------------------------------------------------------------------------------------------------------
local long = ('word '):rep(30)
load({ '  I. T', '', '| a | b |', '+===+===+', '| ' .. long .. '| x |', '| y | z |' }, 5, 4)
current():reformat()
check('no tblwidth, no limit: the cell stays one line', #lines(), 6)

load({ '  I. T', '', '| a | b |', '+===+===+', '| ' .. long .. '| x |', '| y | z |', '{# tblfm; tblwidth: 40 #}' }, 5, 4)
local t40 = current()
check('tblwidth is a setting', t40.config.tblwidth, 40)
t40:reformat()
local out = lines()
local widest = 0
for i = 3, #out - 1 do
  widest = math.max(widest, vim.api.nvim_strwidth(out[i]))
end
check('the table is no wider than tblwidth', widest <= 40, true)
local back = current()
check('the broken lines are one row: still three rows', #back.rows, 3)
check('the text of the cell is whole', vim.trim(cell_text(back, 2, 1)), vim.trim(long))
check('the next row is untouched', texts(back)[3], { 'y', 'z' })
check('the row is inside a multi-line block', out[5]:sub(1, 1) .. out[#out - 2]:sub(1, 1), 'v^')
current():reformat()
local settled = lines()
current():reformat()
check('the layout settles: another reformat changes nothing', lines(), settled)
check('and it is still three rows', #current().rows, 3)

-- the settings and the formulas are tags under the table ---------------------------------------------------------------------
load({ '  I. T', '', '| a | b |', '+===+===+', '| 1 | 2 |', '', '{# tblfm; tblwidth: 40 #}' }, 3, 2)
check('a tag after a blank line is not the table\'s', current().config, {})
load({ '  I. T', '', '| a | b |', '+===+===+', '| 1 | 2 |', '{# tblfm; tblwidth: 20 #}', '#[ tblfm; b: a * 2 ] #' }, 3, 2)
local two = current()
check('tags one after the other are one', { two.config.tblwidth, #two.formulas, two.formulas[1].target, two.formulas[1].expr }, { 20, 1, 'b', 'a * 2' })
load({ '  I. T', '', '| a | b |', '+===+===+', '| 1 | 2 |', '#[ tblfm; tblwidth: oops #]' }, 3, 2)
check('a setting that is not valid is told', #current().errors, 1)

-- formulas ------------------------------------------------------------------------------------------------------------------
local function calc(rows, tag, row)
  local text = { '  I. T', '' }
  vim.list_extend(text, rows)
  text[#text + 1] = tag
  load(text, row or 3, 2)
  ops.recalculate()
  return lines()
end

local base = { '| item | qty | price | total |', '+======+=====+=======+=======+', '| a    | 2   | 3.5   |       |', '| b    | 4   | 1.25  |       |', '| sum  |     |       |       |' }
local res = calc(base, '#[ tblfm; total: qty * price ] #')
local t = current()
check('every row of the column is computed', { cell_text(t, 2, 4), cell_text(t, 3, 4), cell_text(t, 4, 4) }, { '7', '5', '' })
check('the formula tag stays', res[#res], '#[ tblfm; total: qty * price ] #')

res = calc(base, '#[ tblfm ] total = qty * price :: rlast_total = sum(above) #')
t = current()
check('a total of the rows above, in the last row', { cell_text(t, 2, 4), cell_text(t, 3, 4), cell_text(t, 4, 4) }, { '7', '5', '12' })

res = calc(base, '#[ tblfm ] total = round(qty * price / 3, 2) #')
t = current()
check('a body holds what the head cannot: commas', cell_text(t, 2, 4), '2.33')

res = calc(base, '{# tblfm; tblwidth: 60; total: qty * price; r3c4: 100 #}')
t = current()
check('settings and formulas intermixed, a cell by its place', { cell_text(t, 2, 4), cell_text(t, 3, 4), cell_text(t, 4, 4), t.config.tblwidth }, { '7', '5', '100', 60 })

res = calc(base, '#[ tblfm ] $4=$2*$3 #')
t = current()
check('org\'s formula line works', cell_text(t, 2, 4), '7')

res = calc(base, '#[ tblfm ] r2to3_total = n * 10 #')
t = current()
check('a range of rows, the column by name', { cell_text(t, 2, 4), cell_text(t, 3, 4), cell_text(t, 4, 4) }, { '', '20', '30' })

res = calc(base, '#[ tblfm ] total = qty / 0 #')
t = current()
check('a formula that fails leaves the cell', cell_text(t, 2, 4), '')

local before_bad = calc(base, '#[ tblfm ] nope = 1 #')
check('a target that does not exist changes nothing', before_bad[5], '| a    | 2   | 3.5   |       |')

load({ '  I. T', '', '| a | b |', '+===+===+', '| 1 | 9 |', '#[ tblfm ] b = a + 1 #' }, 3, 2)
local changed = ops.recalculate_all(0, true)
check('all the tables of a note', { changed, cell_text(current(), 2, 2) }, { 1, '2' })
load({ '  I. T', '', '| a | b |', '+===+===+', '| 1 | 9 |', '#[ tblfm ] b = a + 1 #', '', '| c |', '+===+', '| 5 |', '#[ tblfm ] c = 6 #' }, 3, 2)
check('two tables: from the last to the first', ops.recalculate_all(0, true), 2)
check('both computed', { cell_text(current(), 2, 2), lines()[10] }, { '2', '| 6 |' })

-- on save ------------------------------------------------------------------------------------------------------------------
require('fey.config').fey_table_recalculate_on_save = true
load({ '  I. T', '', '| a | b |', '+===+===+', '| 1 | 9 |', '#[ tblfm ] b = a + 5 #' }, 3, 2)
local file = vim.fn.tempname() .. '.fey'
vim.cmd('silent write! ' .. vim.fn.fnameescape(file))
check('a saved note has its formulas computed', vim.fn.readfile(file)[5], '| 1 | 6 |')
require('fey.config').fey_table_recalculate_on_save = false

print(('table: %d checks, %d failures'):format(total, failures))
vim.cmd(failures == 0 and 'qa!' or 'cq!')
