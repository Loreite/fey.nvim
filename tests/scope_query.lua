-- Queries and database views over several vaults. Run from the repo root:
--
--   FEY_PARSER=/path/to/fey.so nvim --headless --clean -l tests/scope_query.lua
vim.opt.rtp:prepend('.')
if vim.env.FEY_PARSER then vim.treesitter.language.add('fey', { path = vim.env.FEY_PARSER }) end

local failures, total = 0, 0
local function check(name, got, want)
  total = total + 1
  if not vim.deep_equal(got, want) then
    failures = failures + 1
    print(('FAIL %s\n  got:  %s\n  want: %s'):format(name, vim.inspect(got), vim.inspect(want)))
  end
end

local base = vim.fn.tempname()
vim.fn.mkdir(base, 'p')
base = vim.uv.fs_realpath(base)
local court_dir = base .. '/feyfiles'
require('fey.config'):extend({ fey_court_dir = court_dir })

local tree = require('fey.hollow.tree')
local court = require('fey.hollow.court')
local registry = require('fey.vault')
local pages = require('fey.query.pages')

local function write(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  vim.fn.writefile(lines, path)
end
local function mkvault(dir, files)
  vim.fn.mkdir(dir .. '/.fey', 'p')
  for name, lines in pairs(files or {}) do write(dir .. '/' .. name, lines) end
end
local function scan(root)
  local vault = registry.open(root)
  local done = false
  vault:scan({}, function() done = true end)
  vim.wait(3000, function() return done end, 10)
  return vault
end

court.ensure_dirs()
local alpha, child, beta = base .. '/alpha', base .. '/alpha/child', base .. '/beta'
mkvault(alpha, {
  ['a.fey'] = { '{# table; title: A; rating: 5 #}', '{# labels, shared #}', '', '  I. {# status, TODO, A #} Alpha task', '{# deadline, 2026-10-09 Fri #}', '' },
})
mkvault(child, { ['c.fey'] = { '{# table; title: C; rating: 3 #}', '{# labels, shared #}', '', '  I. {# status, DONE #} Child task', '' } })
mkvault(beta, {
  ['b.fey'] = {
    '{# table; title: B; rating: 4 #}',
    '{# labels, other #}',
    '',
    '  I. {# status, TODO #} Beta task',
    '',
    'see {@ link, court:alpha/a.fey @}',
    '',
  },
})
for _, root in ipairs({ alpha, child, beta }) do
  tree.register_chain(root)
  scan(root)
end
scan(court_dir)

local api = require('fey.api')
local av = api.court().get('court:alpha')
local function names(result)
  return vim.tbl_map(function(r) return r[1].path end, result.rows)
end
local function files(src, scope_spec)
  local result = av:run_query(src, { scope = scope_spec })
  return vim.tbl_map(function(r) return (r[1].hollow or '-') .. ':' .. r[1].path end, result.rows)
end

-- pages of several vaults ------------------------------------------------------------------------
check('current', files('TABLE rating', 'current'), { 'court:alpha:a.fey' })
check('default is current', files('TABLE rating'), { 'court:alpha:a.fey' })
check('tree', files('TABLE rating', 'tree'), { 'court:alpha:a.fey', 'court:alpha:child:c.fey' })
check('court', files('TABLE rating', 'court'), { 'court:alpha:a.fey', 'court:alpha:child:c.fey', 'court:beta:b.fey' })
check('a list is in the order it is written', files('TABLE rating', { 'court:beta', 'current' }), { 'court:beta:b.fey', 'court:alpha:a.fey' })
check('a list with a vault and what is below it', files('TABLE rating', { 'court:alpha:*' }), { 'court:alpha:a.fey', 'court:alpha:child:c.fey' })
check('file.hollow', av:run_query('TABLE file.hollow', { scope = 'court' }).rows[3][2], 'court:beta')
check('where over all vaults', files('TABLE rating WHERE rating >= 4', 'court'), { 'court:alpha:a.fey', 'court:beta:b.fey' })
check('sort over all vaults', av:run_query('TABLE rating SORT rating', { scope = 'court' }).rows[1][2], 3)
check('group by hollow', #av:run_query('TABLE rows.file.name GROUP BY file.hollow', { scope = 'court' }).rows, 3)

-- sources work inside each vault
check('from a label', files('TABLE rating FROM #shared', 'court'), { 'court:alpha:a.fey', 'court:alpha:child:c.fey' })
check('from a label not in a vault', files('TABLE rating FROM #other', 'court'), { 'court:beta:b.fey' })
check('from a folder name', #files('TABLE rating FROM "a.fey"', 'court'), 1)
check('negated', files('TABLE rating FROM !#shared', 'court'), { 'court:beta:b.fey' })
check('combined', files('TABLE rating FROM #shared OR #other', 'court'), { 'court:alpha:a.fey', 'court:alpha:child:c.fey', 'court:beta:b.fey' })

-- tasks over all vaults
local function tasks(src, spec)
  return vim.tbl_map(function(i) return i.task.text end, av:run_query(src, { scope = spec }).items)
end
check('tasks of the tree', tasks('TASK', 'tree'), { 'Alpha task', 'Child task' })
check('open tasks of every vault', tasks('TASK WHERE !completed', 'court'), { 'Alpha task', 'Beta task' })
check('tasks keep their dates', av:run_query('TASK WHERE deadline', { scope = 'court' }).count, 1)

-- links from one vault to another
local lines = require('fey.query.render').lines(av:run_query('TASK WHERE !completed', { scope = 'court' }), { hollow_id = 'court:alpha' })
check('a link to a file of the same vault is plain', lines[1]:match('{@ link, ([^;]-);'), 'a.fey')
check('a link to another vault says which', lines[2]:match('{@ link, ([^;]-);'), 'court:beta/b.fey')
local b_outlinks = api.court().get('court:beta'):run_query('TABLE file.outlinks', { scope = 'current' }).rows[1][2]
check('an outlink to another vault carries it', { b_outlinks[1].path, b_outlinks[1].hollow }, { 'a.fey', 'court:alpha' })
check('and equals the link of that page', require('fey.query.values').equals(b_outlinks[1], av:run_query('TABLE file.link').rows[1][2]), true)

-- a database over several vaults ------------------------------------------------------------------------------
local Model = require('fey.db.model')
local dbstore = require('fey.db.store')
local serialize = require('fey.db.serialize')

local def = { name = 'All', version = 1, scope = 'court', views = { { name = 'Table', columns = { { prop = 'file.hollow' }, { prop = 'file.name' }, { prop = 'rating' } } } } }
check('the scope is written', serialize.encode(def):find('scope_:  court', 1, true) ~= nil, true)
check('and read back', serialize.decode(serialize.encode(def)).scope, 'court')
def.scope = { 'court:alpha:*', 'court:beta' }
check('a list is read back', serialize.decode(serialize.encode(def)).scope, { 'court:alpha:*', 'court:beta' })
def.scope = 'court'

local model = Model.new(registry.open(alpha), def)
local res = model:compute(def.views[1])
check('rows of every vault', #res.rows, 3)
local hollows = {}
for _, row in ipairs(res.rows) do
  hollows[#hollows + 1] = require('fey.query.ops').get(require('fey.query.ops').get(row, 'file'), 'hollow')
end
check('each row knows its hollow', hollows, { 'court:alpha', 'court:alpha:child', 'court:beta' })
check('properties of all vaults', vim.tbl_contains(vim.tbl_map(function(p) return p.id end, model:properties()), 'rating'), true)
check('a row knows the vault to write to', pages.vault_of(res.rows[3]).root, beta)
check('the vault of a derived row', pages.vault_of(require('fey.query.pages').derive(res.rows[3], { x = 1 }, { 'x' })).root, beta)

model.base.scope = nil
check('current again', #model:compute(def.views[1]).rows, 1)
model.base.scope = 'tree'
check('the scope follows the base', #model:compute(def.views[1]).rows, 2)

-- editing a cell writes to the file of its own vault ------------------------------------------------------------
local source_edit = require('fey.db.source_edit')
model.base.scope = 'court'
local row = model:compute(def.views[1]).rows[3]
check('edit a row of another vault', source_edit.set(pages.vault_of(row), 'b.fey', 'rating', 9), true)
check('it is written to that vault', vim.fn.readfile(beta .. '/b.fey')[1]:find('rating: 9', 1, true) ~= nil, true)
check('and the other vault is untouched', vim.fn.readfile(alpha .. '/a.fey')[1], '{# table; title: A; rating: 5 #}')

-- an unsaved buffer is written to, not the file
vim.cmd('edit ' .. vim.fn.fnameescape(alpha .. '/a.fey'))
local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(buf, 4, 5, false, { '{# deadline, 2026-10-10 Sat #}' })
check('the buffer is modified', vim.bo[buf].modified, true)
check('edit a cell of a file with an unsaved buffer', source_edit.set(pages.vault_of(model:compute(def.views[1]).rows[1]), 'a.fey', 'rating', 7), true)
check('the buffer has the new value', vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]:find('rating: 7', 1, true) ~= nil, true)
check('and kept the unsaved edit', vim.api.nvim_buf_get_lines(buf, 4, 5, false)[1], '{# deadline, 2026-10-10 Sat #}')
check('the file on the disk is not changed', vim.fn.readfile(alpha .. '/a.fey')[1], '{# table; title: A; rating: 5 #}')
check('the buffer is still unsaved', vim.bo[buf].modified, true)

-- query tags take a scope -------------------------------------------------------------------------------------
local query = require('fey.query')
local function scope_of(src)
  local b = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { src })
  vim.b[b].did_ftplugin = true
  vim.bo[b].filetype = 'fey'
  vim.treesitter.start(b, 'fey')
  local node = query.query_tags(b)[1]
  return query.scope_of(require('fey.files.elements.tags').parse_tag_node(b, node))
end
check('no scope', scope_of('{# query, TABLE x #}'), nil)
check('scope court', scope_of('{# query, TABLE x; scope: court #}'), 'court')
check('scope tree', scope_of('{# query, TABLE x; scope: tree #}'), 'tree')
check('a list', scope_of('{# query, TABLE x; scope: court:alpha court:beta:* #}'), { 'court:alpha', 'court:beta:*' })

if failures > 0 then
  print(('%d of %d checks failed'):format(failures, total))
  vim.cmd('cquit 1')
end
print(('ok: %d checks'):format(total))
vim.cmd('qa!')
