-- Nested vaults, registration with the nearest vault, references, scopes and links between vaults. Run
-- from the repo root:
--
--   FEY_PARSER=/path/to/fey.so nvim --headless --clean -l tests/tree.lua
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
local scope = require('fey.hollow.scope')
local court = require('fey.hollow.court')
local registry = require('fey.vault')

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
local function ids(list) return vim.tbl_map(function(v) return v.id end, list) end

court.ensure_dirs()

-- proj is a vault with a vault inside it, with a vault inside that; other is next to it
local proj, sub, deep, other = base .. '/proj', base .. '/proj/sub', base .. '/proj/sub/deep', base .. '/other'
mkvault(proj, { ['p.fey'] = { '  I. {# status, TODO #} In proj', '' }, ['notes/n.fey'] = { '  I. Note', '' } })
mkvault(sub, { ['s.fey'] = { '  I. {# status, TODO #} In sub', '' } })
mkvault(deep, { ['d.fey'] = { '  I. {# status, DONE #} In deep', '' } })
mkvault(other, { ['o.fey'] = { '  I. {# status, TODO #} In other', '' } })

-- finding vaults -------------------------------------------------------------------------
check('the nearest vault above', tree.parent_root(deep), sub)
check('above that', tree.parent_root(sub), proj)
check('a vault with none above', tree.parent_root(proj), nil)
check('ancestors', tree.ancestors(deep), { sub, proj })
check('the vault of a file', tree.hollow_root_of(deep .. '/d.fey'), deep)
check('the vault of a file in a plain folder', tree.hollow_root_of(proj .. '/notes/n.fey'), proj)
check('a file with no vault', tree.hollow_root_of(base .. '/nothing/x.fey'), nil)

-- a vault stops at the next vault ------------------------------------------------------------
local pv = scan(proj)
local files = vim.tbl_map(function(r) return r.path end, pv:query('SELECT path FROM files ORDER BY path'))
check('files of proj', files, { 'notes/n.fey', 'p.fey' })
check('proj does not index files of sub', pv:rel_of(sub .. '/s.fey'), nil)
check('and does index its own', pv:rel_of(proj .. '/notes/n.fey'), 'notes/n.fey')
check('sub has its own', vim.tbl_map(function(r) return r.path end, scan(sub):query('SELECT path FROM files')), { 's.fey' })
check('and not the ones of deep', registry.open(sub):rel_of(deep .. '/d.fey'), nil)

-- registration with the nearest vault ----------------------------------------------------------
tree.register_chain(deep)
check('proj registers with the court', vim.tbl_map(function(e) return e.name end, tree.entries(court_dir)), { 'proj' })
check('sub registers with proj', vim.tbl_map(function(e) return e.name end, tree.entries(proj)), { 'sub' })
check('deep registers with sub', vim.tbl_map(function(e) return e.name end, tree.entries(sub)), { 'deep' })
check('and not with the court', #tree.entries(court_dir), 1)
check('ids', { tree.id_of(court_dir), tree.id_of(proj), tree.id_of(sub), tree.id_of(deep) }, {
  'court', 'court:proj', 'court:proj:sub', 'court:proj:sub:deep',
})
check('a vault that is not registered has no id', tree.id_of(other), nil)
tree.register_chain(other)
check('registered', tree.id_of(other), 'court:other')
check('registering again is fine', { tree.register(other), #tree.entries(court_dir) }, { 'other', 2 })

-- names ------------------------------------------------------------------------------------------
check('a name is checked', { tree.valid_name(court_dir, 'proj') }, { false, 'there is already a hollow named proj' })
check('keywords are taken', (tree.valid_name(court_dir, 'court')), false)
check('odd names', (tree.valid_name(court_dir, 'a b')), false)
check('a free name', (tree.valid_name(court_dir, 'fresh')), true)
local twin = base .. '/elsewhere/other'
mkvault(twin)
check('a taken name gets a number', tree.register(twin), 'other-2')
tree.unregister(court_dir, 'other-2')
tree.write_settings(twin, { name = 'second' })
check('the setting is the name', tree.register(twin), 'second')
check('the settings are read back', tree.settings(twin), { name = 'second', merge = true })
check('and the id follows', tree.id_of(twin), 'court:second')

-- settings -------------------------------------------------------------------------------------------
tree.write_settings(twin, { name = 'second', merge = false })
check('merge: false', tree.settings(twin), { name = 'second', merge = false })
check('the file is a data tag', vim.fn.readfile(twin .. '/.fey/hollow.fey'), { '{# table; name: second; merge: false #}' })

-- references -------------------------------------------------------------------------------------------
check('a reference', tree.parse_ref('court:proj:sub/s.fey'), { keyword = 'court', names = { 'proj', 'sub' }, path = 's.fey' })
check('a vault', tree.parse_ref('court:proj'), { keyword = 'court', names = { 'proj' } })
check('the court itself', tree.parse_ref('court/agenda/a.fey'), { keyword = 'court', names = {}, path = 'agenda/a.fey' })
check('current', tree.parse_ref('current:sub/s.fey'), { keyword = 'current', names = { 'sub' }, path = 's.fey' })
check('a plain path is not one', tree.parse_ref('notes/n.fey'), nil)
check('nor an url', tree.parse_ref('https://x.org/a'), nil)
check('nor a folder that looks like one', tree.parse_ref('masters/x.fey'), nil)
check('resolve', { tree.resolve_ref('court:proj:sub/s.fey') }, { sub, 's.fey' })
check('resolve current', { tree.resolve_ref('current:sub:deep/d.fey', proj) }, { deep, 'd.fey' })
check('resolve the court', { tree.resolve_ref('court/agenda/a.fey') }, { court_dir, 'agenda/a.fey' })
check('an unknown vault', { select(3, tree.resolve_ref('court:nope/x.fey')) }, { 'no hollow named nope in court' })
check('format in another vault', tree.format_ref(deep, 'd.fey', proj), 'court:proj:sub:deep/d.fey')
check('format in the same vault', tree.format_ref(proj, 'p.fey', proj), 'p.fey')

-- scopes -----------------------------------------------------------------------------------------------
for _, root in ipairs({ court_dir, proj, sub, deep, other, twin }) do scan(root) end
check('current', ids((scope.resolve('current', sub))), { 'court:proj:sub' })
check('tree', ids((scope.resolve('tree', proj))), { 'court:proj', 'court:proj:sub', 'court:proj:sub:deep' })
check('tree of a leaf', ids((scope.resolve('tree', deep))), { 'court:proj:sub:deep' })
check('court leaves out a vault that opted out', ids((scope.resolve('court'))), {
  'court', 'court:other', 'court:proj', 'court:proj:sub', 'court:proj:sub:deep',
})
check('the vault that opted out sees itself', ids((scope.resolve('current', twin))), { 'court:second' })
check('and its own tree', ids((scope.resolve('tree', twin))), { 'court:second' })
check('a list names vaults', ids((scope.resolve({ 'court:other', 'court:second' }))), { 'court:other', 'court:second' })
check('a list can ask for a vault and what is below it', ids((scope.resolve({ 'court:proj:*' }))), {
  'court:proj', 'court:proj:sub', 'court:proj:sub:deep',
})
check('a list relative to the current vault', ids((scope.resolve({ 'current:sub:deep' }, proj))), { 'court:proj:sub:deep' })
local _, errors = scope.resolve({ 'court:nope' })
check('a reference that does not resolve is reported', errors, { 'no hollow named nope in court' })

-- an opted out vault takes its subtree with it
mkvault(twin .. '/inner', { ['i.fey'] = { '  I. {# status, TODO #} Inner', '' } })
tree.register_chain(twin .. '/inner')
scan(twin .. '/inner')
check('below it', tree.id_of(twin .. '/inner'), 'court:second:inner')
check('not in the court scope', ids((scope.resolve('court'))), {
  'court', 'court:other', 'court:proj', 'court:proj:sub', 'court:proj:sub:deep',
})
check('in the tree scope of the vault', ids((scope.resolve('tree', twin))), { 'court:second', 'court:second:inner' })

-- merged data -------------------------------------------------------------------------------------------
check('tasks of the whole tree', vim.tbl_map(function(t) return t.hollow .. ':' .. t.title end, scope.tasks('court')), {
  'court:other:In other', 'court:proj:In proj', 'court:proj:sub:In sub', 'court:proj:sub:deep:In deep',
})
check('tasks of a tree', vim.tbl_map(function(t) return t.title end, scope.tasks('tree', proj, { done = false })), { 'In proj', 'In sub' })
check('tasks of one vault', #scope.tasks('current', sub), 1)
check('a row says where to write', scope.tasks('current', sub)[1].abs, sub .. '/s.fey')
check('a list of vaults', #scope.tasks({ 'court:proj:sub:deep', 'court:other' }), 2)

-- links between vaults ------------------------------------------------------------------------------------
write(proj .. '/p.fey', {
  '  I. {# status, TODO #} In proj',
  '',
  'see {@ link, court:other/o.fey; desc: Other @} and {@ link, current:sub/s.fey @} and {@ link, court:proj:sub:deep @}',
  'and {@ section, I., court:other/o.fey @}',
  '',
})
registry.open(proj):index_path(proj .. '/p.fey')
local links = registry.open(proj):query('SELECT kind, target, target_ref, target_file, target_sig FROM links ORDER BY line, id')
check('links name their vault', vim.tbl_map(function(l) return { l.kind, l.target_ref, l.target_file } end, links), {
  { 'link', 'court:other', 'o.fey' },
  { 'link', 'current:sub', 's.fey' },
  { 'link', 'court:proj:sub:deep', nil },
  { 'section', 'court:other', 'o.fey' },
})
check('a section tag with a vault', links[4].target_sig, 'I')

-- backlinks of a file of another vault
local back = registry.open(proj):foreign_backlinks(other, 'o.fey')
check('foreign backlinks', vim.tbl_map(function(r) return r.path .. ':' .. r.kind end, back), { 'p.fey:link', 'p.fey:section' })
check('with a heading', #registry.open(proj):foreign_backlinks(other, 'o.fey', 'I.'), 1)
check('not for a vault that is not named', #registry.open(proj):foreign_backlinks(sub, 'o.fey'), 0)
check('a vault link is not a backlink of a file of the vault it is in', #registry.open(other):backlinks('o.fey'), 0)
local all = scope.backlinks('court', nil, other, 'o.fey')
check('backlinks over a scope', vim.tbl_map(function(r) return r.hollow .. ':' .. r.path .. ':' .. r.kind end, all), {
  'court:proj:p.fey:link', 'court:proj:p.fey:section',
})
check('and where to find them', all[1].abs, proj .. '/p.fey')
check('backlinks from a smaller scope', #scope.backlinks('current', other, other, 'o.fey'), 0)

-- following them --------------------------------------------------------------------------------------------
local links_mod = require('fey.links')
check('resolve a link to another vault', links_mod.resolve_path('court:other/o.fey', proj .. '/p.fey'), other .. '/o.fey')
check('relative to the current vault', links_mod.resolve_path('current:sub/s.fey', proj .. '/p.fey'), sub .. '/s.fey')
check('a vault only has no file', links_mod.resolve_path('court:proj:sub:deep', proj .. '/p.fey'), nil)
check('a file that is not there', links_mod.resolve_path('court:other/none.fey', proj .. '/p.fey'), nil)

vim.cmd('edit ' .. vim.fn.fnameescape(proj .. '/p.fey'))
vim.api.nvim_win_set_cursor(0, { 3, 8 })
links_mod.open_at_cursor(vim.api.nvim_get_current_buf())
check('following a link opens the file of the other vault', vim.fn.expand('%:p'), other .. '/o.fey')

vim.cmd('edit ' .. vim.fn.fnameescape(proj .. '/p.fey'))
local line = vim.api.nvim_buf_get_lines(0, 2, 3, false)[1]
vim.api.nvim_win_set_cursor(0, { 3, (line:find('court:proj:sub:deep', 1, true)) })
local start = vim.fn.getcwd()
links_mod.open_at_cursor(vim.api.nvim_get_current_buf())
check('following a vault goes to the vault', vim.fn.getcwd(), deep)
vim.cmd('cd ' .. vim.fn.fnameescape(start))

-- naming a vault when it is created --------------------------------------------------------------------------------
local fresh = base .. '/fresh'
vim.fn.mkdir(fresh, 'p')
local notify = vim.notify
local messages = {}
vim.notify = function(msg) messages[#messages + 1] = msg end
check('a taken name is refused', registry.init(fresh, { name = 'other' }), nil)
check('with the reason', messages[#messages], 'fey hollow: there is already a hollow named other')
check('nothing was registered', tree.name_in(court_dir, fresh), nil)

registry.init(fresh, { name = 'brand-new' })
check('a free name is used', tree.name_in(court_dir, fresh), 'brand-new')
check('and kept in the vault', tree.settings(fresh).name, 'brand-new')

-- the user is asked, and asked again for a name that is taken
local asked = {}
local input = vim.ui.input
vim.ui.input = function(opts, cb)
  asked[#asked + 1] = { opts.default, opts.prompt }
  cb(#asked == 1 and 'other' or 'asked-name')
end
local third = base .. '/third'
vim.fn.mkdir(third, 'p')
registry.init(third)
check('asked twice', #asked, 2)
check('the first time with the directory name', asked[1][1], 'third')
check('the second time with the reason', asked[2][2]:match('there is already a hollow named other') ~= nil, true)
check('the answer is the name', tree.name_in(court_dir, third), 'asked-name')

-- a nested vault is asked for a name in the vault it is in
vim.ui.input = function(opts, cb) asked[#asked + 1] = { opts.default, opts.prompt }; cb('child') end
local nested = proj .. '/child'
vim.fn.mkdir(nested, 'p')
registry.init(nested)
check('named in the vault above', tree.name_in(proj, nested), 'child')
check('the prompt says where', asked[#asked][2]:match('court:proj') ~= nil, true)
check('and it is not in the court', tree.name_in(court_dir, nested), nil)
vim.ui.input = input
vim.notify = notify

-- a vault created above existing ones takes them -------------------------------------------------------------------
local late = base .. '/late'
mkvault(late .. '/a')
tree.register_chain(late .. '/a')
check('registered with the court first', tree.id_of(late .. '/a'), 'court:a')
vim.fn.mkdir(late .. '/.fey', 'p')
local misplaced
for _, e in ipairs(tree.entries(court_dir)) do if e.name == 'a' then misplaced = e.misplaced end end
check('now it belongs below the new vault', misplaced, true)
check('and is not listed as a child', vim.tbl_contains(vim.tbl_map(function(e) return e.name end, tree.children(court_dir)), 'a'), false)
tree.register_chain(late .. '/a')
check('registering again moves it', { tree.id_of(late .. '/a'), tree.id_of(late) }, { 'court:late:a', 'court:late' })
check('the stale registration is pruned', tree.prune(court_dir), { 'a' })

-- taking a vault out of merged views -----------------------------------------------------------------------------------
court.setup()
registry.attach(other)
vim.cmd('FeyHollowMerge off')
check('opted out', tree.settings(other).merge, false)
check('and gone from the court scope', vim.tbl_contains(ids((scope.resolve('court'))), 'court:other'), false)
vim.cmd('FeyHollowMerge on')
check('opted in again', tree.settings(other).merge, true)
check('and back in the court scope', vim.tbl_contains(ids((scope.resolve('court'))), 'court:other'), true)
vim.cmd('FeyHollowMerge')
check('no argument toggles', tree.settings(other).merge, false)

if failures > 0 then
  print(('%d of %d checks failed'):format(failures, total))
  vim.cmd('cquit 1')
end
print(('ok: %d checks'):format(total))
vim.cmd('qa!')
