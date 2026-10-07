-- Database tests (serialization, filters, model, write-back, tag export). Run from the repo root:
--
--   FEY_PARSER=/path/to/fey.so nvim --headless -u NONE -l tests/db.lua
vim.opt.rtp:prepend('.')
if vim.env.FEY_PARSER then vim.treesitter.language.add('fey', { path = vim.env.FEY_PARSER }) end
require('fey.config'):extend({ fey_court_dir = vim.fn.tempname() .. '/court' }) -- never the real court

local failures, total = 0, 0
local function check(name, got, want)
  total = total + 1
  if not vim.deep_equal(got, want) then
    failures = failures + 1
    print(('FAIL %s\n  got:  %s\n  want: %s'):format(name, vim.inspect(got), vim.inspect(want)))
  end
end
local function norm(x) return vim.json.decode(vim.json.encode(x)) end

-- serialization round trip
local serialize = require('fey.db.serialize')
local data = {
  name = 'My Notes', flag = true, num = '123', txt = 'true', multi = 'line1\nline2\n  indented',
  views = { {
    name = 'Table',
    filters = { kind = 'group', mode = 'and', items = {
      { kind = 'cond', prop = 'rating', op = 'gt', value = '3' },
      { kind = 'expr', expr = 'contains(file.labels, "a") and x < 3 [[y]]' },
    } },
    columns = { { prop = 'file.name', width = 24 }, { prop = 'note prop', display = 'Hi, there' } },
    limit = 10,
  } },
}
local back = serialize.decode(serialize.encode(data))
check('serialize round trip', norm(back), norm(data))

-- filters
local filters = require('fey.db.filters')
check('cond exists', filters.build_cond({ kind = 'cond', prop = 'rating', op = 'exists' }), 'rating != null')
check('cond length', filters.build_cond({ kind = 'cond', prop = 'file.labels', op = 'len_gt', value = '2' }), 'length(file.labels) > 2')
check('cond contains', filters.build_cond({ kind = 'cond', prop = 'title', op = 'contains', value = 'a b' }), 'contains(title, "a b")')
check('odd property name', filters.prop_expr('Some Key'), 'row["Some Key"]')
check('group not', filters.build({ kind = 'group', mode = 'not', items = { { kind = 'expr', expr = 'a' }, { kind = 'expr', expr = 'b' } } }), '!((a) or (b))')
check('validate bad', filters.validate('a ((') ~= nil, true)

-- write-back
local source_edit = require('fey.db.source_edit')
local src = table.concat({
  '{# table; title: T; rating: 4 #}', '[ table #]', 'k_:  v', 'tags_:', '    -  a', '    -  b', '[# table ]', '', '  I. Head', '',
}, '\n')
local function edited(key, value)
  local edits = assert(source_edit.plan(src, key, value))
  return source_edit.apply(src, edits)
end
check('edit attr', edited('rating', 5):match('^[^\n]*'), '{# table; title: T; rating: 5 #}')
check('edit attr escapes', edited('title', 'a, b'):match('^[^\n]*'), '{# table; title: a\\, b; rating: 4 #}')
check('edit bullet', edited('k', 'changed'):match('k_:  (%w+)'), 'changed')
check('append attr', edited('status', 'open'):match('^[^\n]*'), '{# table; title: T; rating: 4; status: open #}')
check('edit list', edited('tags', { 'x', 'y', 'z' }):match('tags_:\n(.-)\n%[#'), '    -  x\n    -  y\n    -  z')
check('clear attr', edited('rating', nil):match('^[^\n]*'), '{# table; title: T #}')
check('new list block', edited('fresh', { 'a', 'b' }):match('^%[ table #%]\nfresh_:\n    %-  a\n    %-  b\n%[# table %]\n') ~= nil, true)
check('parse list', source_edit.parse_input('a, b, 3', 'list'), { 'a', 'b', 3 })
check('parse number', source_edit.parse_input('4.5', 'number'), 4.5)
check('parse clear', source_edit.parse_input('  ', nil), nil)

-- vault backed model and tag export
local root = vim.fn.tempname()
vim.fn.mkdir(root .. '/.fey', 'p')
vim.fn.mkdir(root .. '/notes', 'p')
local function write(path, lines) vim.fn.writefile(lines, root .. '/' .. path) end
for i = 1, 4 do
  write(('notes/n%d.fey'):format(i), {
    ('{# table; title: Note %d; rating: %d; status: %s #}'):format(i, i, i % 2 == 0 and 'open' or 'done'),
    '{# labels, ' .. (i % 2 == 0 and 'design' or 'markup') .. ' #}', '', '  I. Note ' .. i, '',
  })
end
local Vault = require('fey.vault.vault')
local vault = Vault.new(root, require('fey.config').vault)
vault:scan({}, function() end)
vim.wait(5000, function() return vault.state == 'ready' end, 10)
check('vault ready', vault.state, 'ready')

local store = require('fey.db.store')
local name, base = store.create(vault)
check('database file exists', vim.uv.fs_stat(store.path(vault, name)) ~= nil, true)
check('database listed', vim.tbl_map(function(e) return e.name end, store.list(vault)), { name })
check('database loads', store.load(vault, name).views[1].name, 'Table')

local Model = require('fey.db.model')
local model = Model.new(vault, base)
local view = base.views[1]
check('all rows', #model:compute(view).rows, 4)

view.filters = { kind = 'group', mode = 'and', items = { { kind = 'cond', prop = 'rating', op = 'gt', value = '1' }, { kind = 'cond', prop = 'status', op = 'eq', value = 'open' } } }
model:invalidate()
check('filter', #model:compute(view).rows, 2)
view.filters, view.sort, view.limit = nil, { { prop = 'rating', dir = 'desc' } }, 3
model:invalidate()
local res = model:compute(view)
check('sort + limit', { #res.rows, res.total }, { 3, 4 })
check('sorted first', res.rows[1] and require('fey.query.ops').get(require('fey.query.ops').get(res.rows[1], 'file'), 'name'), 'n4')
view.limit = nil
base.formulas = { { name = 'double', expr = 'rating * 2' } }
model:invalidate()
check('formula', model:getter('formula.double')(model:compute(view).rows[1]), 8)
check('summary sum', model:summarize('sum', 'rating', model:compute(view).rows), 10)
check('summary unique', model:summarize('unique', 'status', model:compute(view).rows), 2)
view.group = { prop = 'status', dir = 'asc' }
model:invalidate()
check('groups', #model:compute(view).groups, 2)
view.group = nil

-- edit through the source writer
local rows = model:compute(view).rows
local ok = source_edit.set(vault, 'notes/n1.fey', 'rating', 9)
check('set ok', ok, true)
check('written', vim.fn.readfile(root .. '/notes/n1.fey')[1], '{# table; title: Note 1; rating: 9; status: done #}')
local n1 = assert(vault:get_file('notes/n1.fey'))
check('reindexed', n1.data.rating, 9)

-- tag export
base.views[1].columns = { { prop = 'file.name' }, { prop = 'rating' } }
base.views[1].sort = { { prop = 'rating', dir = 'asc' } }
assert(store.save(vault, name, base))
local lines = require('fey.db.export').table_lines(vault, { db = name, rows = 2 })
check('export lines', lines, {
  '| file.name | rating |', '+===========+========+', '| n2        | 2      |', '| n3        | 3      |',
})
check('export unknown db', (pcall(require('fey.db.export').table_lines, vault, { db = 'nope' })), false)

-- opening in the current window: full screen, and the window is given back
local dbview = require('fey.db.view')
vim.cmd('enew')
local before_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_win_set_buf(0, before_buf)
vim.wo.wrap, vim.wo.number = true, true
local wins_before = #vim.api.nvim_list_wins()
local here = dbview.open(vault, name, 'current')
check('current: no new window', #vim.api.nvim_list_wins(), wins_before)
check('current: the window shows the database', vim.api.nvim_win_get_buf(0), here.bufnr)
check('current: its options are the view options', { vim.wo.wrap, vim.wo.number, vim.wo.winfixbuf }, { false, false, true })
here:close()
check('current: the buffer is back', vim.api.nvim_win_get_buf(0), before_buf)
check('current: and the window options', { vim.wo.wrap, vim.wo.number, vim.wo.winfixbuf }, { true, true, false })
check('current: the view is gone', vim.api.nvim_buf_is_valid(here.bufnr), false)

local split_before = #vim.api.nvim_list_wins()
local in_split = dbview.open(vault, name, 'vsplit')
check('vsplit: a new window', #vim.api.nvim_list_wins(), split_before + 1)
in_split:close()
check('vsplit: closed again', #vim.api.nvim_list_wins(), split_before)

local mappings = require('fey.config').mappings
check('mappings for the current window', { type(mappings.global) }, { 'table' })
local conf = require('fey.config')
conf:extend({ mappings = { prefix = '<Space>' } })
conf:setup_mappings('global')
check('<prefix>bc and <prefix>bL', { vim.fn.maparg('<Space>bc', 'n') ~= '', vim.fn.maparg('<Space>bL', 'n') ~= '' }, { true, true })
check('the commands', { vim.fn.exists(':FeyDbHere') == 2 }, { false })
require('fey.db').setup()
check('FeyDbHere exists after setup', vim.fn.exists(':FeyDbHere'), 2)

vault:close()
vim.fn.delete(root, 'rf')
print(('%d checks, %d failed'):format(total, failures))
vim.cmd(failures == 0 and 'qa!' or 'cquit 1')
