-- Query engine tests. Run from the repo root with a built fey parser:
--
--   FEY_PARSER=/path/to/fey.so nvim --headless -u NONE -l tests/query.lua
--
-- (without FEY_PARSER the parser is looked up on the runtimepath)
vim.opt.rtp:prepend('.')
if vim.env.FEY_PARSER then vim.treesitter.language.add('fey', { path = vim.env.FEY_PARSER }) end
require('fey.config'):extend({})

local V = require('fey.query.values')
local parser = require('fey.query.parser')
local eval = require('fey.query.eval')
local ops = require('fey.query.ops')
local functions = require('fey.query.functions')

local failures, total = 0, 0
local function check(name, got, want)
  total = total + 1
  if not vim.deep_equal(got, want) then
    failures = failures + 1
    print(('FAIL %s\n  got:  %s\n  want: %s'):format(name, vim.inspect(got), vim.inspect(want)))
  end
end

local function ev(src, row)
  local v = eval.compile(parser.parse_expression(src))(eval.new_env(row))
  return V.is_null(v) and 'null' or v
end

-- expressions
check('arith', ev('1 + 2 * 3'), 7)
check('precedence', ev('(1 + 2) * 3'), 9)
check('string concat', ev('"a" + 1'), 'a1')
check('compare', ev('2 > 1 and "b" > "a"'), true)
check('lists', ev('length([1, 2, 3])'), 3)
check('index', ev('[10, 20][1]'), 20)
check('lambda', ev('map([1, 2], (x) => x * 2)'), V.list({ 2, 4 }))
check('filter', ev('filter([1, 2, 3, 4], (x) => x % 2 = 0)'), V.list({ 2, 4 }))
check('choice', ev('choice(1 = 2, "y", "n")'), 'n')
check('null', ev('missing.field'), 'null')
check('default', ev('default(missing, 5)'), 5)
check('object', ev('{a: 1, b: 2}.b'), 2)
check('typeof date', ev('typeof(2026-10-20)'), 'date')
check('date diff', ops.tostring(ev('2026-10-20 - 2026-10-18')), '2 days')
check('date + dur', ops.tostring(ev('2026-10-20 + dur("1 month")')), '2026-11-20')
check('dateformat', ev('dateformat(2026-10-20, "dd MMM yyyy")'), '20 Oct 2026')
check('regexreplace', ev('regexreplace("hello", "l+", "L")'), 'heLo')
check('split', ev('split("a, b,c", ",\\\\s*")'), V.list({ 'a', 'b', 'c' }))
check('contains list substring', ev('contains(["I love sushi"], "love")'), true)
check('econtains list', ev('econtains(["I love sushi"], "love")'), false)
check('sort desc', ev('sort([3, 1, 2], "desc")'), V.list({ 3, 2, 1 }))
check('hyphen field', ev('some-key', V.object({ ['Some Key'] = 7 })), 7)
check('swizzle', ev('rows.n', V.object({ rows = V.list({ V.object({ n = 1 }), V.object({ n = 2 }) }) })), V.list({ 1, 2 }))

-- query structure
local ast = parser.parse('TABLE WITHOUT ID a AS "A", b FROM #x AND "y" WHERE a > 1 SORT b DESC, a GROUP BY c AS d LIMIT 3')
check('ast type', ast.type, 'table')
check('ast without id', ast.without_id, true)
check('ast fields', #ast.fields, 2)
check('ast alias', ast.fields[1].alias, 'A')
check('ast commands', vim.tbl_map(function(c) return c.op end, ast.commands), { 'from', 'where', 'sort', 'group', 'limit' })
check('ast sort desc', ast.commands[3].keys[1].desc, true)
check('parse error', pcall(parser.parse, 'TABLE a ('), false)

-- vault backed queries
local root = vim.fn.tempname()
vim.fn.mkdir(root .. '/.fey', 'p')
vim.fn.mkdir(root .. '/notes', 'p')
local function write(path, lines) vim.fn.writefile(lines, root .. '/' .. path) end
write('notes/alpha.fey', {
  '{# table; status: done; rating: 4; due: 2026-10-20 #}', '{# labels, design #}', '',
  '  I. Alpha', '', 'to {@ link, notes/beta.fey @}', '', '  I.A. Sub', '', 'x',
})
write('notes/beta.fey', { '{# table; status: open; rating: 2 #}', '{# labels, design/ui #}', '', '  I. Beta', '', 'x' })

local Vault = require('fey.vault.vault')
local vault = Vault.new(root, require('fey.config').vault)
vault:scan({}, function() end)
vim.wait(5000, function() return vault.state == 'ready' end, 10)
check('vault ready', vault.state, 'ready')

local engine = require('fey.query.engine')
local render = require('fey.query.render')
local function run(q) return engine.run(vault, q, {}) end
local function names(q)
  local out = {}
  for _, row in ipairs(run(q).rows) do
    out[#out + 1] = row[1].path
  end
  return out
end

check('from label', names('TABLE FROM #design'), { 'notes/alpha.fey', 'notes/beta.fey' })
check('from sublabel', names('TABLE FROM #design/ui'), { 'notes/beta.fey' })
check('from folder', names('TABLE FROM "notes/alpha"'), { 'notes/alpha.fey' })
check('negate', names('TABLE FROM "notes" AND -#design/ui'), { 'notes/alpha.fey' })
check('where', names('TABLE WHERE rating > 3'), { 'notes/alpha.fey' })
check('sort', names('TABLE SORT rating'), { 'notes/beta.fey', 'notes/alpha.fey' })
check('limit', #run('TABLE SORT rating DESC LIMIT 1').rows, 1)
check('incoming', names('TABLE FROM [[beta]]'), { 'notes/alpha.fey' })
check('outgoing', names('TABLE FROM outgoing([[alpha]])'), { 'notes/beta.fey' })
check('sections', #run('TABLE FROM @section AND "notes/alpha"').rows, 2)
check('group', run('TABLE rows.file.name GROUP BY status').rows[1][1], 'done')
check('flatten', #run('TABLE x FLATTEN file.labels AS x').rows, 2)
check('date field', run('TABLE typeof(due) WHERE due').rows[1][2], 'date')
check('task queries run (the notes here have no tasks)', { pcall(run, 'TASK') }, { true, { type = 'task', count = 0, grouped = false, items = {} } })

local lines = render.lines(run('TABLE status SORT file.name'))
check('table lines', lines, {
  '| File                        | status |',
  '+=============================+========+',
  '| {@ link, notes/alpha.fey @} | done   |',
  '| {@ link, notes/beta.fey @}  | open   |',
})
check('list lines', render.lines(run('LIST WITHOUT ID file.name SORT file.name')), { '-  alpha', '-  beta' })
check('empty', render.lines(run('LIST FROM #nope')), { 'No results to show for list query.' })

vault:close()
vim.fn.delete(root, 'rf')
print(('%d checks, %d failed'):format(total, failures))
vim.cmd(failures == 0 and 'qa!' or 'cquit 1')
