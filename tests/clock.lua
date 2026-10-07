-- The clock and the logbook. Run from the repo root:
--
--   FEY_PARSER=/path/to/fey.so nvim --headless --clean -l tests/clock.lua
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
require('fey.config'):extend({ fey_court_dir = base .. '/court' })

local tree = require('fey.hollow.tree')
local court = require('fey.hollow.court')
local registry = require('fey.vault')
local Date = require('fey.objects.date')
local Clock = require('fey.clock')
local Logbook = require('fey.files.elements.logbook')

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

court.ensure_dirs()
local one, two = base .. '/one', base .. '/two'
write(one .. '/.fey/x', {})
write(two .. '/.fey/x', {})
local yesterday = Date.now():add({ day = -1 })
write(one .. '/a.fey', {
  '{# table; category: Work #}',
  '',
  '  I. {# status, TODO #} Plain task',
  '{# scheduled, 2026-10-06 Tue #}',
  '',
  'some text',
  '',
  '  II. {# status, TODO #} Has a logbook',
  '',
  '[ logbook #]',
  '{# clock, ' .. yesterday:to_tag_value() .. '; end: ' .. yesterday:add({ min = 90 }):to_tag_value() .. '; dur: 1:30 #}',
  '[# logbook ]',
  '',
  'text',
  '',
  '  III. Nested',
  '',
  '  III.A. Child',
  '',
})
write(two .. '/b.fey', { '  I. {# status, TODO #} In another hollow', '' })
for _, root in ipairs({ one, two }) do
  tree.register_chain(root)
  scan(root)
end
vim.fn.delete(one .. '/.fey/x')
vim.fn.delete(two .. '/.fey/x')
vim.cmd('cd ' .. vim.fn.fnameescape(one))

local clock = Clock:new({})
local function rows(path, root)
  return registry.open(root):query(
    "SELECT d.heading_ord, d.line, d.start_ts, d.end_ts, d.end_time FROM dates d JOIN files f ON f.id = d.file_id WHERE d.kind = 'clock' AND f.path = :p ORDER BY d.line",
    { p = path }
  )
end

-- the index -------------------------------------------------------------------------------------------------
local initial = rows('a.fey', one)
check('a finished clock is a date of kind clock', #initial, 1)
check('with its heading, start and end', { initial[1].heading_ord, initial[1].end_ts - initial[1].start_ts }, { 2, 5400 })
check('nothing is running yet', Clock.active(), nil)
check('no statusline without a clock', clock:get_statusline(), '')

-- clock in -------------------------------------------------------------------------------------------------
local ok1 = wait_for(clock:clock_in({ abs = one .. '/a.fey', line = 3 }))
check('clock in', ok1, true)
local text = read(one .. '/a.fey')
local oi = at(text, '[ logbook #]')
check('a logbook is made under the metadata of the heading', { oi, text[oi - 1] }, { 5, '{# scheduled, 2026-10-06 Tue #}' })
check('with one open clock', text[oi + 1]:match('^{# clock, %d%d%d%d%-%d%d%-%d%d %a%a%a %d%d:%d%d #}$') ~= nil, true)
check('closed again', text[oi + 2], '[# logbook ]')
check('a blank line before the text', text[oi + 3], '')
check('the index sees the running clock', #registry.open(one):query("SELECT 1 FROM dates WHERE kind = 'clock' AND end_ts IS NULL"), 1)
local active = Clock.active()
check('the running clock is found', { active and active.title, active and active.path, active and active.hollow, active and active.line }, { 'Plain task', 'a.fey', 'court:one', 3 })
check('the statusline shows it', clock:get_statusline():match('^%(Fey%) %[%d+:%d%d%] %(Plain task%)$') ~= nil, true)

-- clocking in on the same heading continues
check('the same heading does nothing', wait_for(clock:clock_in({ abs = one .. '/a.fey', line = 3 })), false)

-- clocking in somewhere else stops the first, in another file too
local ok2 = wait_for(clock:clock_in({ abs = two .. '/b.fey', line = 1 }))
check('clock in on another heading', ok2, true)
local first = read(one .. '/a.fey')
check('the first clock was stopped, with an end and a duration', first[at(first, '[ logbook #]') + 1]:match('; end: .- ; dur: %d+:%d%d #}') ~= nil or first[at(first, '[ logbook #]') + 1]:match('; end: .-; dur: %d+:%d%d #}') ~= nil, true)
local active2 = Clock.active()
check('and the new one runs, in another hollow', { active2.title, active2.hollow }, { 'In another hollow', 'court:two' })
check('the file of the second has a logbook', at(read(two .. '/b.fey'), '[ logbook #]') ~= nil, true)
check('the statusline follows', clock:get_statusline():match('In another hollow') ~= nil, true)

-- an effort shows in the statusline
registry.open(two):query('SELECT 1')
write(two .. '/b.fey', vim.tbl_map(function(l) return l end, (function()
  local t = read(two .. '/b.fey')
  table.insert(t, 2, '{# prop; effort: 2h #}')
  return t
end)()))
scan(two)
clock:invalidate()
check('the effort is in the statusline', clock:get_statusline():match('/2h%]') ~= nil, true)

-- clock out ------------------------------------------------------------------------------------------------
check('clock out', wait_for(clock:clock_out()), true)
local b = read(two .. '/b.fey')
check('the clock got its end and duration', b[at(b, '{# clock,')]:match('; end: .-; dur: %d+:%d%d #}$') ~= nil, true)
check('nothing runs', Clock.active(), nil)
check('a second clock out says so', wait_for(clock:clock_out()), false)

-- a second clock goes on top of the logbook
wait_for(clock:clock_in({ abs = two .. '/b.fey', line = 1 }))
b = read(two .. '/b.fey')
local lb = at(b, '[ logbook #]')
check('the newest clock is first', { b[lb + 1]:match('^{# clock, [^;]-#}$') ~= nil, b[lb + 2]:find('end:', 1, true) ~= nil }, { true, true })
check('cancel', wait_for(clock:clock_cancel()), true)
b = read(two .. '/b.fey')
check('the cancelled clock is gone', #vim.tbl_filter(function(l) return l:find('{# clock,', 1, true) end, b), 1)

-- cancelling the only clock takes the logbook with it
local nested_line = at(read(one .. '/a.fey'), ' III. Nested')
wait_for(clock:clock_in({ abs = one .. '/a.fey', line = nested_line }))
local n = read(one .. '/a.fey')
check('a heading with a child gets its logbook before the child', at(n, '[ logbook #]', 1) ~= nil, true)
check('the logbook is in the section of the heading, not of the child', (function()
  local li, ci = 0, at(n, 'III.A. Child')
  for i, l in ipairs(n) do
    if l:find('[ logbook #]', 1, true) then li = i end
  end
  local own = at(n, ' III. Nested')
  return li > own and li < ci
end)(), true)
wait_for(clock:clock_cancel())
n = read(one .. '/a.fey')
check('the logbook went with its only clock', #vim.tbl_filter(function(l) return l:find('logbook', 1, true) end, n), 5)
check('and the blank line after it', table.concat(n, '\n'):find('III. Nested\n\n  III.A.', 1, true) ~= nil, true)

-- the logbook object ----------------------------------------------------------------------------------------
vim.cmd('edit ' .. vim.fn.fnameescape(one .. '/a.fey'))
vim.bo.filetype = 'fey'
local has_lb = at(vim.api.nvim_buf_get_lines(0, 0, -1, false), 'Has a logbook')
local heading = require('fey').instance().files:get_closest_heading({ has_lb, 0 })
local logbook = heading:get_logbook()
check('a logbook reads its clocks', { #logbook.items, logbook.items[1].duration.minutes }, { 1, 90 })
check('and its total', logbook:get_total().minutes, 90)
check('nothing active', logbook:is_active(), false)
check('the heading says it is not clocked in', heading:is_clocked_in(), false)
heading:clock_in()
heading = require('fey').instance().files:get_closest_heading({ has_lb, 0 })
check('clocked in through the heading', heading:is_clocked_in(), true)
heading:clock_out()
heading = require('fey').instance().files:get_closest_heading({ has_lb, 0 })
check('and out', heading:is_clocked_in(), false)
check('two clocks now', #heading:get_logbook().items, 2)

-- recalculating a clock the user edited
local line = at(vim.api.nvim_buf_get_lines(0, 0, -1, false), '; dur: 1:30')
vim.api.nvim_buf_set_lines(0, line - 1, line, false, { (vim.api.nvim_buf_get_lines(0, line - 1, line, false)[1]:gsub('dur: 1:30', 'dur: 9:99')) })
check('a clock line is recalculated', Logbook.recalculate_line(0, line), true)
check('to the real time', vim.api.nvim_buf_get_lines(0, line - 1, line, false)[1]:find('dur: 1:30', 1, true) ~= nil, true)
vim.cmd('silent! write')
vim.cmd('enew')

-- the report and the agenda ------------------------------------------------------------------------------------
scan(one)
scan(two)
local Source = require('fey.agenda.source')
local ClockReport = require('fey.clock.report')
local report = ClockReport:new({
  from = Date.now():add({ day = -2 }),
  to = Date.now():add({ day = 1 }),
  source = Source.new({ scope = 'court' }),
}):generate_report()
check('the report has the clocks of both hollows', #report.files_with_clocks, 2)
check('with a total', report.total_duration.minutes >= 90, true)
local lines = ClockReport:new({ from = Date.now():add({ day = -2 }), to = Date.now():add({ day = 1 }), source = Source.new({ scope = 'court' }) }):get_table_report(1)
check('and a table with a rule, a total and a row per heading', { #lines.rows >= 8, lines.rows[3].cells[2].content:find('ALL Total time', 1, true) ~= nil }, { true, true })
check('a heading row jumps to its heading', lines.rows[7].cells[2].reference ~= nil or lines.rows[8].cells[2].reference ~= nil, true)
local old = ClockReport:new({ from = Date.now():add({ day = -30 }), to = Date.now():add({ day = -20 }), source = Source.new({ scope = 'court' }) }):generate_report()
check('nothing outside the range', #old.files_with_clocks, 0)

wait_for(clock:clock_in({ abs = one .. '/a.fey', line = 3 }))
local entries = Source.new({ scope = 'court' }):headings()
local flagged = vim.tbl_map(function(e) return e:get_title() end, vim.tbl_filter(function(e) return e:is_clocked_in() end, entries))
check('the agenda knows which heading is clocked', flagged, { 'Plain task' })
-- through the agenda window
local live = require('fey.agenda'):new({ source = Source.new({ scope = 'court' }) })
live:open_view('todo')
vim.wait(300)
local ln
for i, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
  if l:find('In another hollow', 1, true) then ln = i end
end
vim.api.nvim_win_set_cursor(0, { ln, 0 })
wait_for(live:clock_in())
vim.wait(300)
check('clock in from the agenda switches the clock', Clock.active().title, 'In another hollow')
wait_for(live:clock_out())
check('and clock out from the agenda stops it', Clock.active(), nil)

-- mappings
local conf = require('fey.config')
conf:extend({ mappings = { prefix = '<Space>' } })
local fbuf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(fbuf)
conf:setup_mappings('fey', fbuf)
for _, lhs in ipairs({ '<Space>xi', '<Space>xo', '<Space>xq', '<Space>xj', '<Space>xe' }) do
  check('mapping ' .. lhs, vim.fn.maparg(lhs, 'n', false, true).buffer, 1)
end
local abuf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(abuf)
conf:setup_mappings('agenda', abuf)
for _, lhs in ipairs({ 'I', 'O', 'X', 'R', '<Space>xj', '<Space>xe' }) do
  check('agenda mapping ' .. lhs, vim.fn.maparg(lhs, 'n', false, true).buffer, 1)
end

if failures > 0 then
  print(('%d of %d checks failed'):format(failures, total))
  vim.cmd('cquit 1')
end
print(('ok: %d checks'):format(total))
vim.cmd('qa!')
