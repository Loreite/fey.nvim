-- The court: the top of the tree of hollows, the registry of hollows and the merged view. Run from the repo
-- root:
--
--   FEY_PARSER=/path/to/fey.so nvim --headless --clean -l tests/court.lua
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
local court = require('fey.hollow.court')
local registry = require('fey.vault')

local function ts(s) return os.time({ year = tonumber(s:sub(1, 4)), month = tonumber(s:sub(6, 7)), day = tonumber(s:sub(9, 10)), hour = 0 }) end
local function mkvault(dir, files)
  vim.fn.mkdir(dir .. '/.fey', 'p')
  for name, lines in pairs(files) do
    vim.fn.mkdir(vim.fs.dirname(dir .. '/' .. name), 'p')
    vim.fn.writefile(lines, dir .. '/' .. name)
  end
end
local function wait_ready(vault) return vim.wait(3000, function() return vault.state == 'ready' end, 10) end

-- the directory is created ------------------------------------------------------------
check('root', court.root(), court_dir)
check('not there yet', vim.fn.isdirectory(court_dir), 0)
court.ensure_dirs()
check('the layout', {
  vim.fn.isdirectory(court_dir .. '/.fey'), vim.fn.isdirectory(court_dir .. '/.fey/dbs'),
  vim.fn.isdirectory(court_dir .. '/.fey/hollows'), vim.fn.isdirectory(court_dir .. '/agenda'),
}, { 1, 1, 1, 1 })
check('the agenda directory', court.agenda_dir(), court_dir .. '/agenda')
court.ensure_dirs()
check('ensuring twice is fine', vim.fn.isdirectory(court_dir .. '/agenda'), 1)

-- the court is a vault ----------------------------------------------------------
vim.fn.writefile({ '  I. {# status, TODO, A #} Inbox item', '{# deadline, 2026-10-09 Fri #}', '' }, court_dir .. '/agenda/inbox.fey')
local mv = court.vault()
check('court vault', mv ~= nil and mv.root, court_dir)
mv:scan({}, function() end)
check('court scanned', wait_ready(mv), true)
check('court has its agenda file', mv:query('SELECT path FROM files')[1].path, 'agenda/inbox.fey')
check('same object as the registry has', registry.open(court_dir) == mv, true)

-- other vaults register themselves ---------------------------------------------------------
local a, b = base .. '/work/alpha', base .. '/play/alpha'
mkvault(a, { ['one.fey'] = { '{# labels, shared, work #}', '', '  I. {# status, TODO #} Write', '{# scheduled, 2026-10-06 Tue #}', '' } })
mkvault(b, { ['two.fey'] = { '{# labels, shared #}', '', '  I. {# status, DONE #} Play', '{# closed, 2026-10-05 Mon #}', '' } })

registry.attach(a)
registry.attach(b)
local list = court.list()
check('registered', vim.tbl_map(function(e) return e.name end, list), { 'alpha', 'alpha-2' })
check('the links point at the vault roots', vim.tbl_map(function(e) return e.root end, list), { a, b })
check('available', vim.tbl_map(function(e) return e.ok end, list), { true, true })
check('a registration is a symbolic link', vim.uv.fs_lstat(court_dir .. '/.fey/hollows/alpha').type, 'link')
check('its target holds the index', vim.uv.fs_stat(court_dir .. '/.fey/hollows/alpha/.fey/vault.db') ~= nil, true)
registry.attach(a)
check('registering again does nothing', #court.list(), 2)
check('the court does not register itself', court.register(court_dir), nil)

-- the merged view ---------------------------------------------------------------------------
local done = false
court.refresh(function() done = true end)
check('refresh finishes', vim.wait(5000, function() return done end, 10), true)
check('vaults of the view', vim.tbl_map(function(v) return v.id end, court.hollows()), { 'court', 'court:alpha', 'court:alpha-2' })

local dates = court.dates()
check('dates of all vaults, in order', vim.tbl_map(function(d) return d.hollow .. ':' .. d.kind end, dates), {
  'court:alpha-2:closed', 'court:alpha:scheduled', 'court:deadline',
})
check('a row knows where to write', dates[2].abs, a .. '/one.fey')
check('open dates only', #court.dates({ open_only = true }), 2)
check('dates in a range', #court.dates({ from = ts('2026-10-06'), to = ts('2026-10-07') }), 1)

local tasks = court.tasks()
check('tasks of all vaults', vim.tbl_map(function(t) return t.hollow .. ':' .. t.title .. ':' .. t.state end, tasks), {
  'court:Inbox item:TODO', 'court:alpha:Write:TODO', 'court:alpha-2:Play:DONE',
})
check('open tasks', #court.tasks({ done = false }), 2)
check('labels merged', court.labels(), {
  { label = 'shared', count = 2, hollows = { 'court:alpha', 'court:alpha-2' } },
  { label = 'work', count = 1, hollows = { 'court:alpha' } },
})
check('query', #court.query('SELECT path FROM files'), 3)
check('abs', court.abs('alpha-2', 'two.fey'), b .. '/two.fey')
check('abs of the court', court.abs('court', 'agenda/inbox.fey'), court_dir .. '/agenda/inbox.fey')
check('revision moves with any vault', (function()
  local before = court.revision()
  vim.fn.writefile({ '  I. {# status, TODO #} Write again' }, a .. '/one.fey')
  registry.open(a):index_path(a .. '/one.fey')
  return court.revision() > before
end)(), true)

-- files saved in a vault this session did not open --------------------------------------------
local c = base .. '/other/gamma'
mkvault(c, { ['x.fey'] = { '  I. {# status, TODO #} X', '' } })
court.register(c)
check('found by path', court.vault_for_path(c .. '/x.fey') ~= nil, true)
check('and not outside', court.vault_for_path(base .. '/elsewhere/y.fey'), nil)

-- jumping ------------------------------------------------------------------------------------
local start = vim.fn.getcwd()
court.jump('alpha', { cwd = true, tab = false })
check('jump changes the directory', vim.fn.getcwd(), a)
vim.cmd('cd ' .. vim.fn.fnameescape(start))
court.jump('alpha-2', { cwd = true, tab = true })
check('jump in a new tab', vim.fn.tabpagenr('$'), 2)
check('with the directory of the tab', vim.fn.getcwd(), b)
vim.cmd('tabclose')
local before = vim.fn.getcwd()
court.jump('gamma', { cwd = false, tab = false })
check('jump without the directory', vim.fn.getcwd(), before)
local warned
local notify = vim.notify
vim.notify = function(msg) warned = msg end
court.jump('nope')
check('an unknown vault is reported', warned, 'fey: no hollow named nope')
vim.notify = notify

-- vaults that are gone ------------------------------------------------------------------------
vim.fn.delete(c, 'rf')
local entries = court.list()
local gamma
for _, e in ipairs(entries) do if e.name == 'gamma' then gamma = e end end
check('a vault that is gone is listed as not available', gamma and gamma.ok, false)
check('and left out of the view', vim.tbl_map(function(v) return v.id end, court.hollows()), { 'court', 'court:alpha', 'court:alpha-2' })
check('prune removes it', court.prune(), { 'court:gamma' })
check('and only it', #court.list(), 2)

-- no symbolic links: a file with the path -------------------------------------------------------
local d = base .. '/third/delta'
mkvault(d, { ['y.fey'] = { '  I. y', '' } })
local symlink = vim.uv.fs_symlink
vim.uv.fs_symlink = function() return nil end
check('registered by file', court.register(d), 'delta')
vim.uv.fs_symlink = symlink
check('the file is the registration', vim.uv.fs_stat(court_dir .. '/.fey/hollows/delta.link') ~= nil, true)
local delta
for _, e in ipairs(court.list()) do if e.name == 'delta' then delta = e end end
check('read back', delta and { delta.root, delta.ok }, { d, true })
check('unregister', court.unregister('delta'), true)

-- switched off -----------------------------------------------------------------------------------
require('fey.config'):extend({ fey_court_dir = court_dir, court = { enabled = false } })
check('disabled', court.root(), nil)
check('nothing is registered when disabled', court.register(d), nil)
require('fey.config'):extend({ fey_court_dir = court_dir, court = { enabled = true } })

-- the API --------------------------------------------------------------------------------------
local api_court = require('fey.api').court()
check('api root', api_court.root(), court_dir)
check('api vaults', vim.tbl_map(function(v) return v.id end, api_court.hollows()), { 'court', 'court:alpha', 'court:alpha-2' })
check('api get', api_court.get('alpha-2'):file('two.fey').title, 'Play')
check('api tasks', #api_court.tasks(), 3)
check('api vault dates', #api_court.get('alpha-2'):dates(), 1)

-- live indexing of an unsaved buffer ---------------------------------------------------------------
registry.setup()
local file = a .. '/one.fey'
vim.cmd('edit ' .. vim.fn.fnameescape(file))
local buf = vim.api.nvim_get_current_buf()
local av = registry.open(a)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '  I. {# status, DONE #} Written live', '' })
vim.api.nvim_exec_autocmds('TextChanged', { buffer = buf })
vim.wait(1000, function() return av:tasks({ path = 'one.fey' })[1].state == 'DONE' end, 20)
check('the text of a buffer is indexed', av:tasks({ path = 'one.fey' })[1].title, 'Written live')
vim.cmd('write')
check('and after saving', av:tasks({ path = 'one.fey' })[1].state, 'DONE')
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '  I. {# status, TODO #} Never saved', '' })
vim.api.nvim_exec_autocmds('TextChanged', { buffer = buf })
vim.wait(1000, function() return av:tasks({ path = 'one.fey' })[1].title == 'Never saved' end, 20)
check('unsaved text', av:tasks({ path = 'one.fey' })[1].title, 'Never saved')
vim.cmd('bdelete!')
check('discarding it restores the disk', av:tasks({ path = 'one.fey' })[1].title, 'Written live')

if failures > 0 then
  print(('%d of %d checks failed'):format(failures, total))
  vim.cmd('cquit 1')
end
print(('ok: %d checks'):format(total))
vim.cmd('qa!')
