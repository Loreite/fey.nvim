-- The navigator over documents, directories and hollows. Run from the repo root:
--
--   FEY_PARSER=/path/to/fey.so nvim --headless --clean -l tests/navigator.lua
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

vim.o.columns = 200
vim.o.lines = 50
local base = vim.fn.tempname()
vim.fn.mkdir(base, 'p')
base = vim.uv.fs_realpath(base)
local court_dir = base .. '/feyhollow'
require('fey.config'):extend({ fey_court_dir = court_dir })

local tree = require('fey.hollow.tree')
local court = require('fey.hollow.court')
local registry = require('fey.vault')
local nav = require('fey.ui.navigator')
local levels = require('fey.ui.navigator.levels')

local function write(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  vim.fn.writefile(lines, path)
end
local function mkhollow(dir, files)
  vim.fn.mkdir(dir .. '/.fey', 'p')
  for name, lines in pairs(files or {}) do write(dir .. '/' .. name, lines) end
end

court.ensure_dirs()
write(court_dir .. '/agenda/inbox.fey', { '  I. Inbox', '' })
local proj, sub, other = base .. '/proj', base .. '/proj/sub', base .. '/other'
mkhollow(proj, {
  ['p.fey'] = { '  I. Project', '', '  I.A. Part', '' },
  ['notes/n.fey'] = { '  I. Notes', '', '  I.A. First', '', '  I.B. Second', '' },
  ['notes/m.fey'] = { '  I. Memo', '' },
  ['plain.txt'] = { 'not a fey file' },
})
mkhollow(sub, { ['s.fey'] = { '  I. Sub', '' } })
mkhollow(other, { ['o.fey'] = { '  I. Other', '' } })
mkhollow(base .. '/empty')
for _, root in ipairs({ proj, sub, other, base .. '/empty' }) do tree.register_chain(root) end

local function lines(buf) return vim.api.nvim_buf_get_lines(buf, 0, -1, false) end
local function labels(s)
  return vim.tbl_map(function(l) return vim.trim(l:gsub('^%s*%S+%s', ''):gsub('%s+$', '')) end, lines(s.nav_buf))
end
local function parent_labels(s)
  return vim.tbl_map(function(l) return vim.trim(l:gsub('^%s*%S+%s', '')) end, lines(s.par_buf))
end
local function marked(s)
  local marks = vim.api.nvim_buf_get_extmarks(s.par_buf, vim.api.nvim_create_namespace('fey_navigator'), 0, -1, { details = true })
  for _, m in ipairs(marks) do
    if m[4].hl_group == 'FeyNavParentCurrent' then return m[2] + 1 end
  end
end
local function open_file(path)
  vim.cmd('edit ' .. vim.fn.fnameescape(path))
  return nav.open()
end

-- levels -------------------------------------------------------------------------------------
check('files and directories', vim.tbl_map(function(i) return i.label end, levels.dir_items(proj)), { 'notes/', 'sub/', 'p.fey' })
check('the files of a directory', vim.tbl_map(function(i) return i.label end, levels.dir_items(proj .. '/notes')), { 'm.fey', 'n.fey' })
check('a hollow directory is marked', vim.tbl_map(function(i) return i.hollow or false end, levels.dir_items(proj)), { false, true, false })
check('hollows below a hollow', vim.tbl_map(function(i) return i.label end, levels.hollow_items(proj)), { 'sub' })
check('hollows of the court', vim.tbl_map(function(i) return i.label end, levels.hollow_items(court_dir)), { 'empty', 'other', 'proj' })
check('the court alone at the top', vim.tbl_map(function(i) return i.label end, levels.hollow_items(nil)), { 'court' })
check('up from a directory', levels.parent_loc({ kind = 'dir', path = proj .. '/notes' }), { kind = 'dir', path = proj })
check('up from a hollow inside a hollow', levels.parent_loc({ kind = 'dir', path = sub }), { kind = 'dir', path = proj })
check('up from a hollow with none above', levels.parent_loc({ kind = 'dir', path = proj }), { kind = 'hollows', parent = court_dir })
check('up from the court directory', levels.parent_loc({ kind = 'dir', path = court_dir }), { kind = 'hollows' })
check('up from the hollows of a hollow', levels.parent_loc({ kind = 'hollows', parent = proj }), { kind = 'hollows', parent = court_dir })
check('up from the hollows of the court', levels.parent_loc({ kind = 'hollows', parent = court_dir }), { kind = 'hollows' })
check('nothing above the court', levels.parent_loc({ kind = 'hollows' }), nil)
check('the hollow level of a file', { levels.hollow_level_for(sub .. '/s.fey') }, { { kind = 'hollows', parent = proj }, sub })
check('and of a top level hollow', { levels.hollow_level_for(proj .. '/p.fey') }, { { kind = 'hollows', parent = court_dir }, proj })

-- a document ---------------------------------------------------------------------------------------
local s = open_file(proj .. '/notes/n.fey')
check('opens on the document', s.mode, 'doc')
check('with the categories', labels(s)[1]:match('Headings') ~= nil, true)
check('the parent pane lists the directory of the file', parent_labels(s), { 'm.fey', 'n.fey' })
check('and marks the file', marked(s), 2)
check('three panes', { s.par_win ~= nil, vim.api.nvim_win_is_valid(s.nav_win), vim.api.nvim_win_is_valid(s.prev_win) }, { true, true, true })

s:enter() -- Headings
check('deeper in the document the parent pane shows the level before', #parent_labels(s) >= 1 and parent_labels(s)[1]:match('Headings') ~= nil, true)
check('and marks where we came from', marked(s), 1)
s:up()
check('up inside the document', { s.mode, #s.stack }, { 'doc', 1 })

-- out of the document, up through the directories to the hollow -------------------------------------
s:up()
check('out of the document into its directory', { s.mode, s.tframe.loc }, { 'tree', { kind = 'dir', path = proj .. '/notes' } })
check('the directory listing', labels(s), { 'm.fey', 'n.fey' })
check('with the cursor on the file', s:current().path, proj .. '/notes/n.fey')
check('the parent pane lists the directory above', parent_labels(s), { 'notes/', 'sub/', 'p.fey' })
check('and marks the directory', marked(s), 1)
check('the preview shows the file', vim.tbl_contains(lines(s.prev_buf), '  I.A. First'), true)
s:up()
check('up to the root of the hollow', s.tframe.loc, { kind = 'dir', path = proj })
check('with the directory selected', s:current().label, 'notes/')
check('the root listing', labels(s), { 'notes/', 'sub/', 'p.fey' })
check('the hollow inside is marked in the listing', lines(s.nav_buf)[2]:find('◈', 1, true) ~= nil, true)
check('the parent pane of a top level hollow lists the hollows of the court', parent_labels(s), { 'empty', 'other', 'proj' })
check('and marks it', marked(s), 3)
s:up()
check('up into the hollows of the court', s.tframe.loc, { kind = 'hollows', parent = court_dir })
check('listing them', labels(s), { 'empty', 'other', 'proj' })
check('on the hollow we came from', s:current().label, 'proj')
check('the preview describes it', vim.tbl_contains(lines(s.info_buf), '  id        court:proj'), true)
local vault_line
for _, l in ipairs(lines(s.info_buf)) do vault_line = vault_line or l:match('vault%s+(.*)') end
check('with its vault', vault_line ~= nil and (vault_line:match('^%d+ files$') ~= nil or vault_line == 'not indexed'), true)
s:up()
check('up to the court', s.tframe.loc, { kind = 'hollows' })
check('where it is the only item', labels(s), { 'court' })
check('and nothing is above', parent_labels(s), { '' })
s:up()
check('the top stays', s.tframe.loc, { kind = 'hollows' })
s:close()

-- down again --------------------------------------------------------------------------------------------
s = nav.hollows()
check('opens on the hollows', { s.mode, s.tframe.loc.kind }, { 'tree', 'hollows' })
check('at the hollow of the buffer', s:current().label, 'proj')
s:enter()
check('into the hollows below it', { s.tframe.loc, labels(s) }, { { kind = 'hollows', parent = proj }, { 'sub' } })
s:enter()
check('a hollow with none below opens its directory', s.tframe.loc, { kind = 'dir', path = sub })
s:up()
check('back up to the hollow containing it', s.tframe.loc, { kind = 'dir', path = proj })
s:up()
check('on proj in the hollows of the court', { s.tframe.loc, s:current().label }, { { kind = 'hollows', parent = court_dir }, 'proj' })
s:enter_local()
check('tab goes to the directory even with hollows below', s.tframe.loc, { kind = 'dir', path = proj })
s:up()
check('back on proj', s:current().label, 'proj')
s:close()

s = open_file(proj .. '/p.fey')
s:up()
check('a file in the root of a hollow', s.tframe.loc, { kind = 'dir', path = proj })
s:select(1)
check('enter a directory', { s:current().label }, { 'notes/' })
s:enter()
check('lists its files', { s.tframe.loc, labels(s) }, { { kind = 'dir', path = proj .. '/notes' }, { 'm.fey', 'n.fey' } })
s:select(1)
s:enter()
check('enter a file: it becomes a document', { s.mode, vim.api.nvim_buf_get_name(s.bufnr) }, { 'doc', proj .. '/notes/m.fey' })
check('the file was loaded to look at it', s.loaded[s.bufnr], true)
check('with its categories', labels(s)[1]:match('Headings') ~= nil, true)
s:enter()
check('into the headings', #labels(s), 1)
s:up()
s:up()
check('and back out again', { s.mode, s.tframe.loc }, { 'tree', { kind = 'dir', path = proj .. '/notes' } })
s:enter()
check('the place in the document was kept', { s.mode, #s.stack }, { 'doc', 1 })
local looked_at = s.bufnr
s:close()
check('a file that was only looked at is not left loaded', vim.api.nvim_buf_is_valid(looked_at) and vim.api.nvim_buf_is_loaded(looked_at), false)

-- a hollow inside a hollow ----------------------------------------------------------------------------------
s = open_file(sub .. '/s.fey')
s:up()
check('the directory of the hollow inside', s.tframe.loc, { kind = 'dir', path = sub })
s:up()
check('up goes on through the directories of the hollow it lives in', s.tframe.loc, { kind = 'dir', path = proj })
check('with the hollow inside selected', s:current().label, 'sub/')
s:up()
check('then to the hollows of the court', s.tframe.loc, { kind = 'hollows', parent = court_dir })
s:close()

s = open_file(sub .. '/s.fey')
s:hollows()
check('H lists the hollows next to the one we are in', { s.mode, s.tframe.loc, s:current().label }, { 'tree', { kind = 'hollows', parent = proj }, 'sub' })
s:close()

-- jumping ------------------------------------------------------------------------------------------------------
s = open_file(proj .. '/notes/n.fey')
s:enter()
s:enter()
s:move(1)
local want_row = s:current().range[1] + 1
s:jump()
check('jump to an object', { vim.fn.expand('%:p'), vim.api.nvim_win_get_cursor(0)[1] }, { proj .. '/notes/n.fey', want_row })

s = open_file(proj .. '/p.fey')
s:up()
s:select(1)
s:enter()
s:select(1)
s:jump()
check('jump to a file in another directory', vim.fn.expand('%:p'), proj .. '/notes/m.fey')
check('it is a real buffer now', vim.bo.buflisted, true)
write(proj .. '/notes/q.fey', { '  I. Quiet', '', '  I.A. Corner', '' })
vim.cmd('edit ' .. vim.fn.fnameescape(proj .. '/p.fey'))
s = nav.open()
s:up()
s:select(1)
s:enter()
for i, it in ipairs(s:frame()._view) do
  if it.label == 'q.fey' then s:select(i) end
end
s:enter()
check('a file that was not open is shown', { s.mode, s.loaded[s.bufnr] }, { 'doc', true })
s:enter()
s:jump()
check('jump to an object of a file that was only looked at', { vim.fn.expand('%:p'), vim.bo.buflisted }, { proj .. '/notes/q.fey', true })

vim.cmd('edit ' .. vim.fn.fnameescape(proj .. '/p.fey'))
s = nav.hollows({ cwd = true })
s:select(2) -- other
check('on other', s:current().label, 'other')
local before = vim.fn.getcwd()
s:jump()
check('jump to a hollow sets the directory', vim.fn.getcwd(), other)
vim.cmd('cd ' .. vim.fn.fnameescape(before))

vim.cmd('edit ' .. vim.fn.fnameescape(proj .. '/p.fey'))
s = nav.hollows({ cwd = false })
s:select(2)
s:jump({ tab = true })
check('in a new tab', vim.fn.tabpagenr('$'), 2)
check('without the directory', vim.fn.getcwd(), before)
vim.cmd('tabclose')

-- a plain buffer starts among the files ---------------------------------------------------------------------------
vim.cmd('edit ' .. vim.fn.fnameescape(proj .. '/plain.txt'))
s = nav.open()
check('a buffer that is not a document opens its directory', { s.mode, s.tframe.loc }, { 'tree', { kind = 'dir', path = proj } })
s:close()

-- the parent pane is optional -----------------------------------------------------------------------------------------
require('fey.ui.navigator.config').set({ show_parent = false })
s = open_file(proj .. '/p.fey')
check('no parent pane', s.par_win, nil)
s:close()
require('fey.ui.navigator.config').set({})

if failures > 0 then
  print(('%d of %d checks failed'):format(failures, total))
  vim.cmd('cquit 1')
end
print(('ok: %d checks'):format(total))
vim.cmd('qa!')
