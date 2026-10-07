-- Capture: templates, targets, destinations. Run from the repo root:
--
--   FEY_PARSER=/path/to/fey.so nvim --headless --clean -l tests/capture.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
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
local court_dir = base .. '/court'
require('fey.config'):extend({ fey_court_dir = court_dir })

local tree = require('fey.hollow.tree')
local court = require('fey.hollow.court')
local registry = require('fey.vault')
local Date = require('fey.objects.date')
local Template = require('fey.capture.template')
local Capture = require('fey.capture')
local Datetree = require('fey.capture.template.datetree')

local function write(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  vim.fn.writefile(lines, path)
end
local function read(path) return vim.fn.readfile(path) end
local function scan(root)
  local vault = registry.open(root)
  local done = false
  vault:scan({}, function() done = true end)
  vim.wait(3000, function() return done end, 10)
end
local function wait_for(p)
  local done, value, err
  p:next(function(v) done, value = true, v end, function(e) done, err = true, e end)
  vim.wait(5000, function() return done end, 10)
  return value, err
end
local function at(lines, text)
  for i, l in ipairs(lines) do
    if l:find(text, 1, true) then return i, l end
  end
end
local function sig(line) return line and line:match('^%s*(%S+)') end

court.ensure_dirs()
local one = base .. '/one'
write(one .. '/.fey/x', {})
write(one .. '/notes.fey', { '  I. Inbox', '', 'inbox text', '', '  I.A. Existing child', '', '  II. Other', '' })
write(one .. '/log.fey', { '  I. Log', '', 'first', 'second', 'third', '' })
write(one .. '/empty.fey', {})
tree.register_chain(one)
scan(one)
vim.fn.delete(one .. '/.fey/x')
vim.cmd('cd ' .. vim.fn.fnameescape(one))

-- a capture window that is not a window: the text, the template, what a window answers to
local function window(template, lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local w = { template = template, id = 1, killed = false }
  function w:get_bufnr() return buf end
  function w:kill() self.killed = true end
  return w
end
local capture = Capture:new({ files = require('fey').instance().files })
local function write_capture(template_opts, lines, destination)
  local template = Template:new(template_opts)
  local w = window(template, lines)
  capture._windows[w.id] = w
  local ok, err = wait_for(capture:_write(w, destination))
  return ok, err, w
end

-- expansions --------------------------------------------------------------------------------------------
local today = Date.today()
local function compiled(text)
  local t = Template:new({ template = text })
  local lines = wait_for(t:compile())
  return lines
end
check('%t is the date for a tag', compiled('{# scheduled, %t #}')[1], '{# scheduled, ' .. today:to_tag_value() .. ' #}')
check('%T adds the time', compiled('x %T')[1]:match('^x (%d%d%d%d%-%d%d%-%d%d %a%a%a %d%d:%d%d)$') ~= nil, true)
check('%u is an inactive date tag', compiled('made %u')[1]:match('^made {@ date, .+; active: false @}$') ~= nil, true)
check('%<fmt> still works', compiled('%<%Y>')[1], os.date('%Y'))
check('a heading with the status tag', compiled('  I. {# status, TODO #} %?\n{# prop; created: %T #}')[2]:match('^{# prop; created: .- #}$') ~= nil, true)
vim.cmd('edit ' .. vim.fn.fnameescape(one .. '/notes.fey'))
vim.bo.filetype = 'fey'
vim.fn.cursor({ 5, 1 })
check('%a links to the heading it was called from', compiled('see %a')[1], 'see {@ link, court:one/notes.fey; desc: Existing child; section: I.A. @}')
vim.cmd('enew')

-- targets ---------------------------------------------------------------------------------------------------
local function target(t, extra)
  local tpl = Template:new(vim.tbl_extend('force', { target = t }, extra or {}))
  return (tpl:get_target())
end
check('a path is relative to the hollow', target('notes.fey'), one .. '/notes.fey')
check('an absolute path', target(one .. '/log.fey'), one .. '/log.fey')
check('a reference to a file of a hollow', target('court:one/log.fey'), one .. '/log.fey')
check('a reference through the court', target('court/agenda/inbox.fey'), court_dir .. '/agenda/inbox.fey')
check('the default is the inbox of the court', target(''), court_dir .. '/agenda/inbox.fey')
require('fey.config'):extend({ fey_default_notes_file = one .. '/log.fey' })
check('the default notes file wins', target(''), one .. '/log.fey')
require('fey.config'):extend({ fey_default_notes_file = '' })
check('a reference that names nothing', { Template:new({ target = 'court:nope/a.fey' }):get_target() }, { nil, 'no hollow named nope in court' })

-- to the end of a file ---------------------------------------------------------------------------------------
local ok1, err1 = write_capture({ target = 'notes.fey' }, { '  I. {# status, TODO #} Buy milk', '{# prop; created: now #}' })
check('capture runs', { ok1, err1 }, { true, nil })
local notes = read(one .. '/notes.fey')
local bi, bl = at(notes, 'Buy milk')
check('the heading is numbered after the others', sig(bl), 'III.')
check('with its status and prop', { bl:find('status, TODO', 1, true) ~= nil, notes[bi + 1] }, { true, '{# prop; created: now #}' })
check('after what was there', bi > at(notes, 'Other'), true)
check('the index follows', #registry.open(one):query("SELECT 1 FROM headings h JOIN files f ON f.id = h.file_id WHERE f.path = 'notes.fey'"), 4)

-- under a heading: by title, by signature ----------------------------------------------------------------------
write_capture({ target = 'notes.fey', heading = 'Inbox' }, { '  I. Under inbox' })
notes = read(one .. '/notes.fey')
check('a child of the heading found by title', sig(select(2, at(notes, 'Under inbox'))), 'I.B.')
check('after the other child', at(notes, 'Under inbox') > at(notes, 'Existing child'), true)
write_capture({ target = 'notes.fey', heading = 'I.A.' }, { '  I. Deep' })
notes = read(one .. '/notes.fey')
check('a child of the heading found by signature', sig(select(2, at(notes, 'Deep'))), 'I.A.i.')
local _, err_missing = write_capture({ target = 'notes.fey', heading = 'Nowhere' }, { '  I. Lost' })
check('a heading that is not there is an error', type(err_missing) == 'string' or err_missing == nil, true)
check('and nothing is written', at(read(one .. '/notes.fey'), 'Lost'), nil)

-- a regexp ----------------------------------------------------------------------------------------------------
write_capture({ target = 'log.fey', regexp = '^second' }, { 'inserted after second' })
local log = read(one .. '/log.fey')
check('after the line that matches', log[at(log, 'second') + 1], 'inserted after second')

-- padding ---------------------------------------------------------------------------------------------------------
write_capture({ target = 'log.fey', properties = { empty_lines = 1 } }, { '  II. Padded' })
log = read(one .. '/log.fey')
local pi = at(log, 'Padded')
check('blank lines around the text', { log[pi - 1], log[pi + 1] }, { '', '' })

-- the date tree ---------------------------------------------------------------------------------------------------
local d1 = Date.from_string('2026-10-06')
local function dt_capture(date, text)
  return write_capture({ target = 'tree.fey', datetree = { date = date } }, { '  I. ' .. text })
end
write(one .. '/tree.fey', {})
scan(one)
dt_capture(d1, 'first entry')
local tree_lines = read(one .. '/tree.fey')
check('year, month and day headings', {
  sig(select(2, at(tree_lines, '2026'))),
  sig(select(2, at(tree_lines, '2026-10 October'))),
  sig(select(2, at(tree_lines, '2026-10-06 Tuesday'))),
}, { 'I.', 'I.A.', 'I.A.i.' })
check('the entry under the day', sig(select(2, at(tree_lines, 'first entry'))), 'I.A.i.a.')
dt_capture(d1, 'second entry')
tree_lines = read(one .. '/tree.fey')
check('the same day takes it as a second child', sig(select(2, at(tree_lines, 'second entry'))), 'I.A.i.b.')
check('with the day heading made once', #vim.tbl_filter(function(l) return l:find('2026-10-06 Tuesday', 1, true) end, tree_lines), 1)
dt_capture(Date.from_string('2026-10-07'), 'next day')
tree_lines = read(one .. '/tree.fey')
check('a later day is a sibling after it', sig(select(2, at(tree_lines, '2026-10-07 Wednesday'))), 'I.A.ii.')
check('the day is after the earlier one', at(tree_lines, '2026-10-07') > at(tree_lines, 'second entry'), true)
dt_capture(Date.from_string('2026-10-05'), 'earlier day')
tree_lines = read(one .. '/tree.fey')
check('an earlier day goes before and the others renumber', {
  sig(select(2, at(tree_lines, '2026-10-05 Monday'))),
  sig(select(2, at(tree_lines, '2026-10-06 Tuesday'))),
}, { 'I.A.i.', 'I.A.ii.' })
dt_capture(Date.from_string('2026-11-02'), 'next month')
tree_lines = read(one .. '/tree.fey')
check('a new month under the year', sig(select(2, at(tree_lines, '2026-11 November'))), 'I.B.')
dt_capture(Date.from_string('2027-01-04'), 'next year')
tree_lines = read(one .. '/tree.fey')
check('a new year', sig(select(2, at(tree_lines, '2027'))), 'II.')

-- a query ------------------------------------------------------------------------------------------------------------
scan(one)
write_capture({ target = 'log.fey', query = 'TABLE title FROM @section WHERE title = "Inbox"' }, { '  I. Via query' })
notes = read(one .. '/notes.fey')
check('a query picks the destination', at(notes, 'Via query') ~= nil, true)
check('under the heading it found', sig(select(2, at(notes, 'Via query'))), 'I.C.')

-- unique -------------------------------------------------------------------------------------------------------------
local ok_u = write_capture({ target = 'notes.fey', unique = true }, { '  I. Buy milk' })
check('unique refuses a title that exists', ok_u, false)
check('and writes nothing', #vim.tbl_filter(function(l) return l:find('Buy milk', 1, true) end, read(one .. '/notes.fey')), 1)
local ok_u2 = write_capture({ target = 'notes.fey', unique = true }, { '  I. A brand new title' })
check('unique lets a new one in', ok_u2, true)

-- the window --------------------------------------------------------------------------------------------------------
local _, _, w2 = write_capture({ target = 'notes.fey' }, { '  I. Window closes' })
check('the window is closed after writing', w2.killed, true)
check('and forgotten', capture._windows[1], nil)

-- the real window ----------------------------------------------------------------------------------------------
local real = Template:new({ target = 'notes.fey', template = '  I. From a window %?' })
capture:open_template(real)
vim.wait(500, function() return vim.b.fey_capture_window_id ~= nil end, 10)
check('the capture window is open', vim.b.fey_capture == true, true)
check('with the expanded text', vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]:find('From a window', 1, true) ~= nil, true)
vim.api.nvim_buf_set_lines(0, 0, 1, false, { '  I. From a window, finished' })
local before_count = #read(one .. '/notes.fey')
wait_for(capture:refile())
check('finalize writes the text', at(read(one .. '/notes.fey'), 'From a window, finished') ~= nil, true)
check('and the window is gone', vim.b.fey_capture, nil)

local quiet = Template:new({ target = 'notes.fey', template = '  I. Never written %?' })
capture:open_template(quiet)
vim.wait(500, function() return vim.b.fey_capture_window_id ~= nil end, 10)
local qid = vim.b.fey_capture_window_id
vim.cmd('bwipeout!')
vim.wait(200)
check('an untouched window that is closed writes nothing', at(read(one .. '/notes.fey'), 'Never written'), nil)
check('and is forgotten', capture._windows[qid], nil)

-- defaults and mappings ---------------------------------------------------------------------------------------------
check('the default template is Fey text', require('fey.config').fey_capture_templates.t.template, '  I. {# status, TODO #} %?\n{# prop; created: %T #}')
local conf = require('fey.config')
conf:extend({ mappings = { prefix = '<Space>' } })
vim.cmd('enew')
conf:setup_mappings('global')
check('<prefix>c is global', vim.fn.maparg('<Space>c', 'n', false, true).buffer, 0)
local cbuf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(cbuf)
conf:setup_mappings('capture', cbuf)
for _, lhs in ipairs({ '<C-C>', '<Space>r', '<Space>k', 'g?' }) do
  check('capture mapping ' .. lhs, vim.fn.maparg(lhs, 'n', false, true).buffer, 1)
end
local nbuf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(nbuf)
conf:setup_mappings('note', nbuf)
check('note mappings exist', vim.fn.maparg('<C-C>', 'n', false, true).buffer, 1)
check('the help lists capture', table.concat(require('fey.objects.help').prepare_content('capture'), '\n'):find('Write to the destination', 1, true) ~= nil, true)

if failures > 0 then
  print(('%d of %d checks failed'):format(failures, total))
  vim.cmd('cquit 1')
end
print(('ok: %d checks'):format(total))
vim.cmd('qa!')
