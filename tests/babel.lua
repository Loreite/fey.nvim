-- Source blocks: header arguments, the index, tangling and edit special. Run from the repo root:
--
--   FEY_PARSER=/path/to/fey.so nvim --headless --clean -l tests/babel.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
if vim.env.FEY_PARSER then vim.treesitter.language.add('fey', { path = vim.env.FEY_PARSER }) end
vim.cmd('filetype plugin indent on')

local failures, total = 0, 0
local function check(name, got, want)
  total = total + 1
  if not vim.deep_equal(got, want) then
    failures = failures + 1
    print(('FAIL %s\n  got:  %s\n  want: %s'):format(name, vim.inspect(got), vim.inspect(want)))
  end
end

local base = vim.uv.fs_realpath((function()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, 'p')
  return d
end)())
local config = require('fey.config')
require('fey').setup({ fey_court_dir = base .. '/court' })
local Tangle = require('fey.babel.tangle')
local Babel = require('fey.babel')

-- targets ---------------------------------------------------------------------------------
check('no target', Tangle.target(nil, 'lua', '/n/a.fey'), nil)
check('target no', Tangle.target('no', 'lua', '/n/a.fey'), nil)
check('target yes', Tangle.target('yes', 'lua', '/n/a.fey'), '/n/a.lua')
check('target yes, no language', Tangle.target('yes', nil, '/n/a.fey'), '/n/a')
check('absolute target', Tangle.target('/x/out.lua', 'lua', '/n/a.fey'), '/x/out.lua')
check('relative target is next to the file', Tangle.target('src/out.lua', 'lua', '/n/a.fey'), '/n/src/out.lua')
check('dotted target', Tangle.target('./out.lua', 'lua', '/n/a.fey'), '/n/out.lua')
check('dedent', Tangle.dedent({ '   a', '     b', '' }), { 'a', '  b', '' })

-- the plan ------------------------------------------------------------------------------------
local function info(t) return vim.tbl_extend('force', { file = '/n/a.fey', line = 1, noweb = false, mkdirp = false, content = {} }, t) end
local plan = Tangle.plan({
  info({ tangle = '/o/main.lua', noweb = true, content = { 'start()', '  <<body>>', 'stop()' }, line = 3 }),
  info({ name = 'body', content = { 'a()', 'b()' }, line = 8 }),
  info({ name = 'body', content = { 'c()' }, line = 12 }),
  info({ tangle = '/o/main.lua', content = { 'more()' }, line = 16 }),
})
check('references expand with the indent, same names are joined', plan.targets['/o/main.lua'], { 'start()', '  a()', '  b()', '  c()', 'stop()', '', 'more()' })
check('no problem', #plan.problems, 0)
check('blocks written', plan.count, 2)

plan = Tangle.plan({ info({ tangle = '/o/x.lua', noweb = false, content = { '<<body>>' } }), info({ name = 'body', content = { 'a()' } }) })
check('no noweb, no expansion', plan.targets['/o/x.lua'], { '<<body>>' })

plan = Tangle.plan({ info({ tangle = '/o/x.lua', noweb = true, content = { '<<nothing>>' }, line = 5 }) })
check('an unresolved reference is a problem', { plan.problems[1].kind, plan.problems[1].line }, { 'unresolved', 5 })
check('and the line stays', plan.targets['/o/x.lua'], { '<<nothing>>' })

plan = Tangle.plan({
  info({ tangle = '/o/x.lua', noweb = true, content = { '<<a>>' } }),
  info({ name = 'a', content = { '<<b>>' } }),
  info({ name = 'b', content = { '<<a>>' } }),
})
check('blocks that refer to each other are a problem', plan.problems[1] and plan.problems[1].kind, 'cycle')

plan = Tangle.plan({
  info({ file = '/n/a.fey', tangle = '/o/same.lua', content = { 'one' } }),
  info({ file = '/n/b.fey', tangle = '/o/same.lua', content = { 'two' }, line = 4 }),
  info({ file = '/n/b.fey', tangle = '/o/other.lua', content = { 'three' } }),
})
check('two files, one target: a conflict', { plan.problems[1].kind, plan.problems[1].file }, { 'conflict', '/n/b.fey' })
check('the target with a conflict is not written', plan.targets['/o/same.lua'], nil)
check('the others are', plan.order, { '/o/other.lua' })
plan = Tangle.plan({ info({ file = '/n/a.fey', name = 'x', content = { 'in a' } }), info({ file = '/n/b.fey', tangle = '/o/y.lua', noweb = true, content = { '<<x>>' } }) })
check('a name belongs to its file', plan.problems[1] and plan.problems[1].kind, 'unresolved')

-- header arguments, in a file ------------------------------------------------------------------------
local FeyFile = require('fey.files.file')
local function open(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  vim.fn.writefile(lines, path)
  vim.cmd('edit! ' .. vim.fn.fnameescape(path))
  vim.bo.filetype = 'fey'
  vim.treesitter.start(0, 'fey')
  return FeyFile:new({ filename = path, buf = vim.api.nvim_get_current_buf() })
end
local root = base .. '/hollow'
vim.fn.mkdir(root .. '/.fey', 'p')
local source = {
  '{# table; header_args: :mkdirp yes :tangle no #}',
  '',
  '  I. Code',
  '{# prop; header_args: :noweb yes #}',
  '',
  '###  src lua :tangle out/main.lua',
  'print(1)',
  '<<helper>>',
  '###',
  '',
  '###  src lua :name helper',
  'helper()',
  '###',
  '',
  '-  item',
  '',
  '   ###  src python :tangle yes',
  '   x = 1',
  '   ###',
  '',
  '###  src',
  'no language',
  '###',
  '',
  '[ comment #]',
  '###  src lua :tangle hidden.lua',
  'hidden()',
  '###',
  '[# comment ]',
  '',
}
local file = open(root .. '/code.fey', source)
local blocks = file:get_blocks()
check('five blocks', #blocks, 5)
local args = blocks[1]:get_header_args()
check('own over the heading over the file', { args[':tangle'], args[':noweb'], args[':mkdirp'] }, { 'out/main.lua', 'yes', 'yes' })
check('a language is not an argument', args['lua'], nil)
check('language', blocks[1]:get_language(), 'lua')
check('no language', blocks[4]:get_language(), nil)
check('name', blocks[2]:get_name(), 'helper')
check('no name', blocks[1]:get_name(), nil)

local infos = Tangle.infos_of_file(file)
local plan_file = Tangle.plan(infos)
check('plan of a file', plan_file.targets[root .. '/out/main.lua'], { 'print(1)', 'helper()' })
check('the block in a list item is dedented', plan_file.targets[root .. '/code.py'], { 'x = 1' })
check('mkdirp from the file', plan_file.mkdirp[root .. '/out/main.lua'], true)

-- tangle a file
Babel.tangle(file)
check('the file is written', vim.fn.readfile(root .. '/out/main.lua'), { 'print(1)', 'helper()' })
check('with the extension of the language', vim.fn.readfile(root .. '/code.py'), { 'x = 1' })

-- the index -----------------------------------------------------------------------------------------
local registry = require('fey.vault')
local vault = registry.open(root)
local done = false
vault:scan({}, function() done = true end)
vim.wait(5000, function() return done end, 10)
local rows = vault:blocks()
check('indexed blocks (the one in a comment is not)', #rows, 4)
check('row language, name, tangle', { rows[1].language, rows[1].name, rows[1].tangle, rows[1].noweb }, { 'lua', nil, 'out/main.lua', 'yes' })
check('row of a named block', { rows[2].name, rows[2].tangle }, { 'helper', 'no' })
check('row content', rows[1].content, 'print(1)\n<<helper>>')
check('args are merged', rows[1].args[':mkdirp'], 'yes')
check('a block in a list item', { rows[3].language, rows[3].tangle, rows[3].content }, { 'python', 'yes', '   x = 1' })
check('no language in the index', rows[4].language, nil)
check('only blocks with a target', #vault:blocks({ tangle = true }), 2)
check('by language', #vault:blocks({ language = 'python' }), 1)
check('by name', #vault:blocks({ name = 'helper' }), 1)

-- tangle the hollow, and check it
vim.fn.delete(root .. '/out', 'rf')
vim.fn.delete(root .. '/code.py')
local planned = Babel.plan_scope('current', root)
check('the plan from the index', { planned.targets[root .. '/out/main.lua'], planned.targets[root .. '/code.py'] }, { { 'print(1)', 'helper()' }, { 'x = 1' } })
Babel.tangle_scope('current', root)
check('the hollow is tangled', vim.fn.readfile(root .. '/out/main.lua'), { 'print(1)', 'helper()' })

vim.fn.writefile({ '  I. Other', '', '###  src lua :tangle out/main.lua', 'clash()', '###', '', '###  src lua :tangle yes :noweb yes', '<<lost>>', '###' }, root .. '/other.fey')
done = false
vault:scan({}, function() done = true end)
vim.wait(5000, function() return done end, 10)
local problems = Babel.check('current', root)
local kinds = vim.tbl_map(function(p) return p.kind end, problems)
table.sort(kinds)
check('check finds the conflict and the lost reference', kinds, { 'conflict', 'unresolved' })
check('into quickfix', #vim.fn.getqflist(), 2)
vim.cmd('cclose')

-- edit special ---------------------------------------------------------------------------------------------
local ES = require('fey.objects.edit_special')
local function edit(path, text, row, content)
  open(path, text)
  vim.api.nvim_win_set_cursor(0, { row, 0 })
  local es = ES:new()
  es:init_in_fey_buffer()
  es:init()
  local ft = vim.bo.filetype
  local before = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local keys = vim.fn.maparg(config.fey_edit_src_save_exit or '', 'n', false, true)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, content)
  ES:new():write()
  local mapped = vim.fn.maparg(vim.g.mapleader or ',', 'n') -- no leader needed: the mappings are checked by name below
  vim.cmd('q!')
  return ft, before, vim.api.nvim_buf_get_lines(0, 0, -1, false)
end
local ft, before, after = edit(base .. '/es1.fey', { '  I. Code', '', '###  src lua :tangle a.lua', 'print(1)', '###' }, 4, { 'x()', 'y()' })
check('edit special: the language is the file type, not the arguments', { ft, before }, { 'lua', { 'print(1)' } })
check('edit special: written back', after, { '  I. Code', '', '###  src lua :tangle a.lua', 'x()', 'y()', '###' })
ft, _, after = edit(base .. '/es2.fey', { '  I. Code', '', '###  src', 'plain', '###' }, 4, { 'changed' })
check('edit special: a block with no language', { ft, after[4] }, { '', 'changed' })
ft, _, after = edit(base .. '/es3.fey', { '  I. Code', '', '-  item', '', '   ###  src python', '   x = 1', '   ###' }, 6, { 'a = 1', '', 'b = 2' })
check('edit special: the fence indent of a list item is kept', { ft, after[6], after[7], after[8], after[9] }, { 'python', '   a = 1', '', '   b = 2', '   ###' })
ft, _, after = edit(base .. '/es4.fey', { '  I. Code', '', '[ note #]', '###  src lua', 'print(1)', '###', '[# note ]' }, 5, { 'print(2)' })
check('edit special: in a pair tag', { ft, after[5] }, { 'lua', 'print(2)' })

-- the mappings of the edit buffer and the new ones
open(base .. '/es5.fey', { '  I. Code', '', '###  src lua', 'print(1)', '###' })
vim.api.nvim_win_set_cursor(0, { 4, 0 })
local es = ES:new()
es:init_in_fey_buffer()
es:init()
local function mapped(lhs) return vim.fn.maparg(lhs, 'n', false, true).desc end
local prefix = config.mappings.prefix or '<LocalLeader>'
check('the edit buffer has its mappings', {
  mapped('g?'),
  vim.fn.maparg(vim.api.nvim_replace_termcodes(prefix .. 'w', true, false, true), 'n') ~= '',
}, { 'fey show help', true })
vim.cmd('q!')
open(base .. '/es6.fey', { '  I. Code' })
local function has(lhs) return vim.fn.maparg(vim.api.nvim_replace_termcodes(prefix .. lhs, true, false, true), 'n') ~= '' end
check('the tangle mappings are there', { has('yt'), has('yv'), has('yc') }, { true, true, true })

vault:close()
print(('babel: %d checks, %d failures'):format(total, failures))
vim.cmd(failures == 0 and 'qa!' or 'cq!')
