-- Refile, archive and the public agenda API. Run from the repo root:
--
--   FEY_PARSER=/path/to/fey.so nvim --headless --clean -l tests/refile.lua
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

local base = vim.uv.fs_realpath((function()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, 'p')
  return d
end)())
require('fey.config'):extend({ fey_court_dir = base .. '/court' })

local tree = require('fey.hollow.tree')
local court = require('fey.hollow.court')
local registry = require('fey.vault')
local refile = require('fey.refile')
local Promise = require('fey.utils.promise')

local function write(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  vim.fn.writefile(lines, path)
end
local function scan(root)
  local vault = registry.open(root)
  local done = false
  vault:scan({}, function() done = true end)
  vim.wait(3000, function() return done end, 10)
end
local function wait_for(p)
  local done, value, err
  p:next(function(v) done, value = true, v end, function(e) done, err = true, e end)
  vim.wait(4000, function() return done end, 10)
  return value, err
end
local function read(path) return vim.fn.readfile(path) end
local function at(lines, text)
  for i, l in ipairs(lines) do
    if l:find(text, 1, true) then return i, l end
  end
end
local function sig(line) return line and line:match('^%s*(%S+)') end

court.ensure_dirs()
local one, two = base .. '/one', base .. '/two'
local function setup()
  write(one .. '/.fey/x', {})
  write(two .. '/.fey/x', {})
  write(one .. '/src.fey', {
    '  I. First',
    '',
    'first text',
    '',
    '  II. {# status, TODO, A #} Move me',
    '{# deadline, 2026-10-09 Fri #}',
    '',
    'moved text',
    '',
    '  II.A. Child of moved',
    '',
    'child text',
    '',
    '  III. Last',
    '',
    'last text',
    '',
  })
  write(one .. '/dest.fey', {
    '  I. Inbox',
    '',
    'inbox text',
    '',
    '  I.A. Existing child',
    '',
    '  II. Other',
    '',
  })
  write(two .. '/far.fey', { '  I. Far', '', 'far text', '' })
  for _, root in ipairs({ one, two }) do
    tree.register_chain(root)
    scan(root)
  end
  vim.fn.delete(one .. '/.fey/x')
  vim.fn.delete(two .. '/.fey/x')
end
setup()

local function dest_of(abs, title)
  for _, c in ipairs(refile.destinations('court')) do
    if c.dest.abs == abs and (title == nil and c.dest.line == nil or c.dest.title == title) then return c.dest end
  end
end

-- destinations ------------------------------------------------------------------------------------------
local list = refile.destinations('court')
local texts = vim.tbl_map(function(c) return c.text end, list)
check('files are destinations', vim.tbl_contains(texts, 'court:one/dest.fey'), true)
check('and headings', vim.tbl_contains(texts, 'court:one/dest.fey  I.A. Existing child'), true)
check('of every hollow', vim.tbl_contains(texts, 'court:two/far.fey'), true)
check('a heading knows where it is', dest_of(one .. '/dest.fey', 'Inbox').end_line, 6)
check('current scope only', #vim.tbl_filter(function(c) return c.dest.hollow ~= 'court:one' end, refile.destinations('current', one)), 0)

-- under a heading of another file --------------------------------------------------------------------------
local inbox = dest_of(one .. '/dest.fey', 'Inbox')
local result, err = wait_for(refile.move({ abs = one .. '/src.fey', line = 5 }, inbox))
check('refile runs', err, nil)
check('the signature in the new place', result and result.signature, 'I.B.')
local dest = read(one .. '/dest.fey')
local mi, ml = at(dest, 'Move me')
check('the heading lands last under the destination', { sig(ml), mi > at(dest, 'Existing child') }, { 'I.B.', true })
check('with its status and date', { ml:find('status, TODO, A', 1, true) ~= nil, dest[mi + 1] }, { true, '{# deadline, 2026-10-09 Fri #}' })
check('and its subtree one level down, renumbered', sig(select(2, at(dest, 'Child of moved'))), 'I.B.i.')
check('before what came after', at(dest, 'Other') > at(dest, 'Child of moved'), true)
check('the other headings stay as they are', { dest[1], sig(select(2, at(dest, 'Existing child'))) }, { '  I. Inbox', 'I.A.' })
local src = read(one .. '/src.fey')
check('the source lost it', vim.tbl_filter(function(l) return l:find('Move me', 1, true) or l:find('moved text', 1, true) end, src), {})
check('and renumbered', vim.tbl_filter(function(l) return l:find('Last', 1, true) end, src)[1], '  II. Last')
check('the old text stays in order', { src[1], src[3], src[#src - 1] }, { '  I. First', 'first text', 'last text' })
check('the index follows', #registry.open(one):query("SELECT 1 FROM headings h JOIN files f ON f.id = h.file_id WHERE f.path = 'dest.fey'"), 5)
check('no buffer is left behind', vim.fn.bufnr(one .. '/src.fey') == -1 or not vim.api.nvim_buf_is_loaded(vim.fn.bufnr(one .. '/src.fey')), true)

-- to the top level of a file in another hollow --------------------------------------------------------------
write(one .. '/src.fey', { '  I. Keep', '', '  I.A. Deep one', '', 'deep text', '', '  II. Other', '' })
scan(one)
local far = dest_of(two .. '/far.fey')
local r2, e2 = wait_for(refile.move({ abs = one .. '/src.fey', line = 3 }, far))
check('refile to another hollow', e2, nil)
local far_lines = read(two .. '/far.fey')
check('a deep heading becomes a top level one', sig(select(2, at(far_lines, 'Deep one'))), 'II.')
check('after the existing text', { far_lines[1], at(far_lines, 'Deep one') > at(far_lines, 'far text') }, { '  I. Far', true })
check('with its text', at(far_lines, 'deep text') ~= nil, true)
check('the far hollow is indexed', #registry.open(two):query("SELECT 1 FROM headings"), 2)

-- inside one file -------------------------------------------------------------------------------------------
write(one .. '/same.fey', { '  I. A', '', '  II. B', '', '  III. C', '', 'c text', '' })
scan(one)
local c_dest
for _, c in ipairs(refile.destinations('court')) do
  if c.dest.abs == one .. '/same.fey' and c.dest.title == 'A' then c_dest = c.dest end
end
local r3, e3 = wait_for(refile.move({ abs = one .. '/same.fey', line = 5 }, c_dest))
check('refile inside a file', e3, nil)
check('the heading is under the destination', sig(select(2, at(read(one .. '/same.fey'), ' C'))), 'I.A.')
check('text went along', vim.tbl_contains(read(one .. '/same.fey'), 'c text'), true)
check('the others renumbered', sig(select(2, at(read(one .. '/same.fey'), ' B'))), 'II.')
scan(one)
local b_dest
for _, c in ipairs(refile.destinations('court')) do
  if c.dest.abs == one .. '/same.fey' and c.dest.title == 'A' then b_dest = c.dest end
end
local _, e4 = wait_for(refile.move({ abs = one .. '/same.fey', line = 1 }, b_dest))
check('a heading cannot go below itself', type(e4), 'string')
check('and the file is untouched', read(one .. '/same.fey')[1], '  I. A')

-- leave a link ----------------------------------------------------------------------------------------------
write(one .. '/link.fey', { '  I. Stay', '', '  II. Go', '', 'go text', '' })
scan(one)
local to = dest_of(two .. '/far.fey')
local r5, e5 = wait_for(refile.move({ abs = one .. '/link.fey', line = 3 }, to, { leave_link = true }))
check('refile with a link', e5, nil)
local link_text = table.concat(read(one .. '/link.fey'), '\n')
check('a link to the new place is left', link_text:find('{@ link, court:two/far.fey; desc: Go; section: ', 1, true) ~= nil, true)
check('and the heading is gone', link_text:find('go text', 1, true), nil)

-- inbound links are counted ------------------------------------------------------------------------------------
write(one .. '/target.fey', { '  I. Target', '', 'text', '' })
write(one .. '/pointer.fey', { '  I. Pointer', '', 'see {@ section, I., target.fey @}', '' })
scan(one)
local r6 = wait_for(refile.move({ abs = one .. '/target.fey', line = 1 }, dest_of(two .. '/far.fey')))
check('links to the old place are counted', r6 and r6.inbound, 1)

-- archive ---------------------------------------------------------------------------------------------------
write(one .. '/arch.fey', { '  I. Project', '', '  I.A. {# status, DONE #} Old task', '', 'old text', '', '  II. Rest', '' })
scan(one)
local r7, e7 = wait_for(refile.archive({ abs = one .. '/arch.fey', line = 3 }))
check('archive runs', e7, nil)
check('the archive file is the template', vim.uv.fs_stat(one .. '/arch.fey_archive') ~= nil, true)
local archived = read(one .. '/arch.fey_archive')
check('a top level heading', archived[1]:match('^%s*(%S+)'), 'I.')
check('with its status', archived[1]:find('status, DONE', 1, true) ~= nil, true)
local arch_text = table.concat(archived, '\n')
check('and where it came from', arch_text:find('archived_from: court:one/arch.fey', 1, true) ~= nil, true)
check('the titles above it', arch_text:find('archived_path: Project', 1, true) ~= nil, true)
check('the state', arch_text:find('archived_state: DONE', 1, true) ~= nil, true)
check('the date', arch_text:find('archived_at: ', 1, true) ~= nil, true)
check('and its text', arch_text:find('old text', 1, true) ~= nil, true)
check('gone from the document', table.concat(read(one .. '/arch.fey'), '\n'):find('Old task', 1, true), nil)
check('archiving an archive says no', wait_for(refile.archive({ abs = one .. '/arch.fey_archive', line = 1 })), false)
scan(one)
local entries = require('fey.agenda.source').new({ scope = 'court' }):headings()
check('archived headings stay out of the agenda lists', #vim.tbl_filter(function(e) return e:get_title() == 'Old task' end, entries), 0)
check('the vault has them', #registry.open(one):query("SELECT 1 FROM files WHERE path = 'arch.fey_archive'"), 1)

-- the public agenda api -----------------------------------------------------------------------------------------
local api = require('fey.api')
local file = api.file(one .. '/dest.fey')
check('heading_at: a heading line', file:heading_at(1).title, 'Inbox')
check('heading_at: a line of its text', file:heading_at(3).title, 'Inbox')
check('heading_at: the deepest heading', file:heading_at(5).title, 'Existing child')
check('heading_at: outside any heading', api.file(one .. '/same.fey'):heading_at(999), nil)
check('the old position module is gone', pcall(require, 'fey.api.position'), false)

local Agenda = require('fey.api.agenda')
vim.cmd('enew')
check('get_heading_at_cursor is nil outside an agenda', Agenda.get_heading_at_cursor(), nil)
local live = require('fey.agenda'):new({ source = require('fey.agenda.source').new({ scope = 'court' }) })
live:open_view('todo')
vim.wait(300)
local found
for i, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
  if l:find('Move me', 1, true) then found = i end
end
if found then
  vim.api.nvim_win_set_cursor(0, { found, 0 })
  require('fey').instance().agenda = live
  local h = Agenda.get_heading_at_cursor()
  check('the agenda item as an api heading', h and h.title, 'Move me')
  check('which is the real thing', h and h.file.path, 'dest.fey')
end
check('a scope option reaches the view', (function()
  local v = live:open_view('todo', { scope = { 'court:two' } })
  vim.wait(300)
  return live.views[1].source:get_scope()
end)(), { 'court:two' })
check('dates given as strings', (function()
  local ok = pcall(Agenda.agenda, { from = '2026-10-05', span = 'day' })
  vim.wait(200)
  return ok
end)(), true)

-- from a document and from the agenda
write(one .. '/doc.fey', { '  I. One', '', '  II. {# status, TODO #} Two', '', 'two text', '' })
scan(one)
vim.cmd('edit ' .. vim.fn.fnameescape(one .. '/doc.fey'))
vim.bo.filetype = 'fey'
vim.fn.cursor({ 5, 1 })
check('the source at the cursor is the heading it is under', refile.source_at_cursor(), { abs = one .. '/doc.fey', line = 3 })
wait_for(refile.archive_at_cursor())
check('archive from a document', table.concat(read(one .. '/doc.fey_archive'), '\n'):find('Two', 1, true) ~= nil, true)
check('the open buffer follows', table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n'):find('Two', 1, true), nil)

write(one .. '/agenda.fey', { '  I. {# status, TODO #} Archive me from the agenda', '', '  II. {# status, TODO #} Stay', '' })
scan(one)
live:open_view('todo')
vim.wait(300)
local ln
for i, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
  if l:find('Archive me from the agenda', 1, true) then ln = i end
end
vim.api.nvim_win_set_cursor(0, { ln, 0 })
wait_for(live:archive())
vim.wait(300)
check('the agenda archived the item', table.concat(read(one .. '/agenda.fey_archive'), '\n'):find('Archive me from the agenda', 1, true) ~= nil, true)
check('and it left the view', table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n'):find('Archive me from the agenda', 1, true), nil)
check('the rest stays', table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n'):find('Stay', 1, true) ~= nil, true)

-- mappings
local conf = require('fey.config')
conf:extend({ mappings = { prefix = '<Space>' } })
vim.cmd('enew')
vim.bo.filetype = 'fey'
conf:setup_mappings('fey', vim.api.nvim_get_current_buf())
check('refile in documents', vim.fn.maparg('<Space>r', 'n', false, true).buffer, 1)
check('archive in documents', vim.fn.maparg('<Space>$', 'n', false, true).buffer, 1)
check('archive tag in documents', vim.fn.maparg('<Space>A', 'n', false, true).buffer, 1)
local abuf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(abuf)
conf:setup_mappings('agenda', abuf)
check('refile in the agenda', vim.fn.maparg('<Space>r', 'n', false, true).buffer, 1)
check('archive in the agenda', vim.fn.maparg('<Space>$', 'n', false, true).buffer, 1)

if failures > 0 then
  print(('%d of %d checks failed'):format(failures, total))
  vim.cmd('cquit 1')
end
print(('ok: %d checks'):format(total))
vim.cmd('qa!')
