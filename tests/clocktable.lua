-- The clocktable tag. Run from the repo root:
--
--   FEY_PARSER=/path/to/fey.so nvim --headless --clean -l tests/clocktable.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
if vim.env.FEY_PARSER then vim.treesitter.language.add('fey', { path = vim.env.FEY_PARSER }) end
local config = require('fey.config')
config:extend({ fey_court_dir = vim.fn.tempname() .. '/court' }) -- never the real court
config:setup_ts_predicates()

local failures, total = 0, 0
local function check(name, got, want)
  total = total + 1
  if not vim.deep_equal(got, want) then
    failures = failures + 1
    print(('FAIL %s\n  got:  %s\n  want: %s'):format(name, vim.inspect(got), vim.inspect(want)))
  end
end

local CT = require('fey.clock.table')
local Date = require('fey.objects.date')

-- spans -------------------------------------------------------------------------------
local function day(ts) return os.date('%Y-%m-%d %H:%M', ts) end
local from, to = CT.parse_span('2026-10')
check('a month', { day(from), day(to) }, { '2026-10-01 00:00', '2026-10-31 23:59' })
from, to = CT.parse_span('2026-10-01--2026-10-07')
check('a range', { day(from), day(to) }, { '2026-10-01 00:00', '2026-10-07 23:59' })
from, to = CT.parse_span('2026')
check('a year', { day(from), day(to) }, { '2026-01-01 00:00', '2026-12-31 23:59' })
from, to = CT.parse_span('2026-10-07')
check('a day', { day(from), day(to) }, { '2026-10-07 00:00', '2026-10-07 23:59' })
from, to = CT.parse_span('today')
check('today', { day(from), day(to) }, { Date.today():format('%Y-%m-%d') .. ' 00:00', Date.today():format('%Y-%m-%d') .. ' 23:59' })
from, to = CT.parse_span('7d')
check('last 7 days', math.floor((to - from) / 86400 + 0.5), 7)
from, to = CT.parse_span('thisweek')
check('a week is 7 days', math.floor((to - from) / 86400 + 0.5), 7)
check('default is this week', { CT.parse_span('') }, { CT.parse_span('thisweek') })
check('unknown span', { CT.parse_span('nonsense') }, { nil, 'clocktable: unknown span "nonsense"' })

-- the table ------------------------------------------------------------------------------
local root = vim.uv.fs_realpath((function()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, 'p')
  return d
end)())
vim.fn.mkdir(root .. '/.fey', 'p')
local function clock(start, stop, dur)
  return ('{# clock, %s; end: %s; dur: %s #}'):format(start, stop, dur)
end
vim.fn.writefile({
  '  I. Alpha work',
  '[ logbook #]',
  clock('2026-10-05 Mon 09:00', '2026-10-05 Mon 10:30', '1:30'),
  clock('2026-10-06 Tue 09:00', '2026-10-06 Tue 09:45', '0:45'),
  '{# clock, 2026-10-06 Tue 13:00 #}',
  '[# logbook ]',
  '',
  '  II. Other',
  '[ logbook #]',
  clock('2026-10-06 Tue 14:00', '2026-10-06 Tue 15:00', '1:00'),
  clock('2026-09-30 Wed 14:00', '2026-09-30 Wed 15:00', '1:00'),
  '[# logbook ]',
}, root .. '/a.fey')
vim.fn.writefile({
  '  I. Beta',
  '[ logbook #]',
  clock('2026-10-07 Wed 08:00', '2026-10-07 Wed 08:30', '0:30'),
  '[# logbook ]',
}, root .. '/b.fey')

local Vault = require('fey.vault.vault')
local vault = Vault.new(root, config.vault)
vault:scan({}, function() end)
vim.wait(5000, function() return vault.state == 'ready' end, 10)
check('vault ready', vault.state, 'ready')

local function lines(spec) return CT.lines(vault, spec) end
local by_heading = lines({ span = '2026-10' })
check('heading rows', #by_heading, 2 + 3 + 1)
check('heading total', by_heading[#by_heading]:match('^| Total%s+| 3:45 |$') ~= nil, true)
check('header', by_heading[1]:match('^| Heading'), '| Heading')
check('a heading is a link', by_heading[3]:match('^| {@ link, a.fey; section: ') ~= nil or by_heading[3]:match('^| {@ link, a.fey') ~= nil, true)

local by_file = lines({ span = '2026-10', by = 'file' })
check('file rows', #by_file, 2 + 2 + 1)
check('file total', by_file[#by_file]:match('3:45'), '3:45')
local a_row = vim.tbl_filter(function(l) return l:find('a.fey', 1, true) end, by_file)[1]
check('file a', a_row:match('3:15'), '3:15')

local by_day = lines({ span = '2026-10', by = 'day' })
check('day rows', {
  by_day[3]:match('^| 2026%-10%-05 Mon%s*| 1:30 |$') ~= nil,
  by_day[4]:match('^| 2026%-10%-06 Tue%s*| 1:45 |$') ~= nil,
  by_day[5]:match('^| 2026%-10%-07 Wed%s*| 0:30 |$') ~= nil,
}, { true, true, true })

check('a narrower span', lines({ span = '2026-10-06' })[#lines({ span = '2026-10-06' })]:match('1:45'), '1:45')
check('the running clock is not counted', lines({ span = '2026-10-06', by = 'day' })[3]:match('1:45') ~= nil, true)
check('September', lines({ span = '2026-09' })[#lines({ span = '2026-09' })]:match('1:00'), '1:00')
check('nothing in the span', lines({ span = '2025' })[1], 'No clocks to show for this span.')
check('bad by', { pcall(lines, { by = 'weird' }) }, { false, 'clocktable: unknown "by": weird' })

-- as a tag, through the query machinery ---------------------------------------------------
vim.fn.writefile({
  '  I. Report',
  '',
  '{# clocktable; span: 2026-10; by: file #}',
  '',
}, root .. '/report.fey')
vim.cmd('cd ' .. vim.fn.fnameescape(root))
vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/report.fey'))
local buf = vim.api.nvim_get_current_buf()
vim.bo[buf].filetype = 'fey'
vim.treesitter.start(buf, 'fey')
local Tag = require('fey.files.elements.tags')
Tag.setup({})
vim.api.nvim_win_set_cursor(0, { 3, 0 })
require('fey.query').run_at_cursor(buf)
local out = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
check('result tag written', vim.tbl_contains(out, '[ clocktable_result #]') and vim.tbl_contains(out, '[# clocktable_result ]'), true)
check('result holds the total', table.concat(out, '\n'):find('| Total', 1, true) ~= nil, true)
local before = #out
require('fey.query').run_at_cursor(buf)
check('running again replaces it', #vim.api.nvim_buf_get_lines(buf, 0, -1, false), before)

-- `conceal: true` on the tag is written to the result, on every kind of tag
vim.fn.writefile({
  '  I. Hidden',
  '',
  '{# clocktable; span: 2026-10; conceal: true #}',
  '',
  '{# query, LIST WITHOUT ID file.name; conceal: true #}',
  '',
  '{# query, LIST WITHOUT ID file.name #}',
  '',
}, root .. '/hidden.fey')
vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/hidden.fey'))
buf = vim.api.nvim_get_current_buf()
vim.bo[buf].filetype = 'fey'
vim.treesitter.start(buf, 'fey')
require('fey.query').run_all(buf, { silent = true })
local hidden = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
local function count(pattern)
  return #vim.tbl_filter(function(l) return l:match(pattern) end, hidden)
end
check('clocktable result is concealed', count('^%[ clocktable_result; conceal: true #%]$'), 1)
check('query result is concealed', count('^%[ query_result; conceal: true #%]$'), 1)
check('a query without the key has a plain result', count('^%[ query_result #%]$'), 1)
check('the key is not part of the query text', count('error'), 0)
check('the body of a result is written', count('^-  ') >= 2, true)

vault:close()
vim.fn.delete(root, 'rf')
print(('clocktable: %d checks, %d failures'):format(total, failures))
vim.cmd(failures == 0 and 'qa!' or 'cq!')
