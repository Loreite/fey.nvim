-- Tests of the date tag and FeyDate. Run from the repo root:
--
--   FEY_PARSER=/path/to/fey.so nvim --headless --clean -l tests/date_tag.lua
vim.opt.rtp:prepend('.')
if vim.env.FEY_PARSER then vim.treesitter.language.add('fey', { path = vim.env.FEY_PARSER }) end
require('fey.config'):extend({})

local Date = require('fey.objects.date')
local Tag = require('fey.files.elements.tags')
local edit = require('fey.files.elements.tags.edit')

local failures, total = 0, 0
local function check(name, got, want)
  total = total + 1
  if not vim.deep_equal(got, want) then
    failures = failures + 1
    print(('FAIL %s\n  got:  %s\n  want: %s'):format(name, vim.inspect(got), vim.inspect(want)))
  end
end

local function buffer(lines)
  local buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.b[buf].did_ftplugin = true
  vim.bo[buf].filetype = 'fey'
  vim.treesitter.start(buf, 'fey')
  return buf
end

-- from_tag_value ----------------------------------------------------------------
local d = Date.from_tag_value('2026-10-06 Tue 10:00-11:00 +1w -3d', { active = true })[1]
check('value date', { d.year, d.month, d.day, d.hour, d.min }, { 2026, 10, 6, 10, 0 })
check('value time range', os.date('%H:%M', d.timestamp_end), '11:00')
check('value adjustments', d.adjustments, { '+1w', '-3d' })
check('value has time', d:has_time(), true)
check('value date only', Date.from_tag_value('2026-10-06')[1]:has_time(), false)
check('value invalid', Date.from_tag_value('tomorrow'), {})

local pair = Date.from_tag_value('2026-10-06 Tue--2026-10-08 Thu')
check('range count', #pair, 2)
check('range days', { pair[1].day, pair[2].day }, { 6, 8 })
check('range flags', { pair[1].is_date_range_start, pair[2].is_date_range_end }, { true, true })
check('range related', pair[1].related_date == pair[2], true)
check('range keeps a delay out of the range', #Date.from_tag_value('2026-10-06 Tue --3d'), 1)

-- from_tag ---------------------------------------------------------------------
local buf = buffer({
  '  I. Head',
  '',
  '{@ date, 2026-10-06 Tue 10:00 @} {@ date, 2026-10-07; active: false @}',
  '{# scheduled, 2026-10-08 Thu +1w #} {# closed, 2026-10-09 Fri #}',
  '{# deadline, 2026-10-10; warn: 3d; time: 12:30; repeat: +1m #}',
  '{# closed, 2026-10-09; active: true #}',
})
local function tag_at(row, col)
  vim.api.nvim_win_set_cursor(0, { row, col })
  return edit.at_cursor(buf)
end
local function dates_at(row, col, opts) return Date.from_tag(tag_at(row, col), opts) end

local a = dates_at(3, 5)[1]
check('tag active by default', a.active, true)
check('tag type none', a.type, 'NONE')
check('tag range is the value', { a.range.start_line, a.range.start_col, a.range.end_col }, { 3, 10, 29 })
check('tag inactive', dates_at(3, 40)[1].active, false)
local s = dates_at(4, 5)[1]
check('scheduled type', s.type, 'SCHEDULED')
check('scheduled active', s.active, true)
check('scheduled adjustments', s.adjustments, { '+1w' })
local c = dates_at(4, 40)[1]
check('closed type', c.type, 'CLOSED')
check('closed inactive by default', c.active, false)
check('closed can be active', dates_at(6, 5)[1].active, true)
local dl = dates_at(5, 5)[1]
check('deadline keys', { dl.hour, dl.min, dl.adjustments }, { 12, 30, { '+1m', '-3d' } })

-- from_node with the source text ---------------------------------------------------
local src = '{@ date, 2026-10-06 Tue @}\n'
local root = vim.treesitter.get_string_parser(src, 'fey'):parse()[1]:root()
local node = root:named_descendant_for_range(0, 5, 0, 5)
while node and node:type() ~= 'scope_tag' do node = node:parent() end
check('from_node on a source string', Date.from_node(node, src)[1].day, 6)

-- writing ----------------------------------------------------------------------
check('to_tag_value', Date.from_string('2026-10-06 Tue 10:00 +1w'):to_tag_value(), '2026-10-06 Tue 10:00 +1w')
check('to_tag_text', Date.from_string('2026-10-06 Tue', { active = true }):to_tag_text(), '{@ date, 2026-10-06 Tue @}')
check(
  'to_tag_text inactive',
  Date.from_string('2026-10-06 Tue', { active = true }):to_tag_text({ active = false }),
  '{@ date, 2026-10-06 Tue; active: false @}'
)
check(
  'to_tag_text scheduled',
  Date.from_string('2026-10-06 Tue 10:00', { type = 'SCHEDULED', active = true }):to_tag_text(),
  '{# scheduled, 2026-10-06 Tue 10:00 #}'
)
check(
  'to_tag_text closed',
  Date.from_string('2026-10-06 Tue', { type = 'CLOSED', active = false }):to_tag_text(),
  '{# closed, 2026-10-06 Tue #}'
)
check(
  'to_tag_text range',
  Date.from_tag_value('2026-10-06 Tue--2026-10-08 Thu', { active = true })[1]:to_tag_text(),
  '{@ date, 2026-10-06 Tue--2026-10-08 Thu @}'
)
local round = Date.from_tag_value('2026-10-06 Tue 10:00-11:00 +1w -3d')[1]
check('round trip', round:to_tag_value(), '2026-10-06 Tue 10:00-11:00 +1w -3d')

-- the text of a written tag is read back by the grammar
buf = buffer({ '  I. Head', '', Date.from_string('2026-10-06 Tue 10:00 +1w -3d', { active = true }):to_tag_text({ active = false }) })
local back = Date.from_tag(tag_at(3, 5))
check('written tag is read back', { back[1]:to_tag_value(), back[1].active }, { '2026-10-06 Tue 10:00 +1w -3d', false })

-- handler: the calendar is replaced by a stub that picks the 20th ------------------------
Tag.setup({})
check('handler registered', type(Tag.handlers.date.scope_tag), 'function')
check('planning handler registered', type(Tag.handlers.scheduled.scope_tag), 'function')

local Calendar = require('fey.objects.calendar')
local Promise = require('fey.utils.promise')
Calendar.new = function(data)
  return {
    open = function() return Promise.resolve(data.date:set({ day = 20 })) end,
  }
end

buf = buffer({ '  I. Head', '', 'a {@ date, 2026-10-06 Tue 10:00 +1w @} b', '{# scheduled, 2026-10-06 Tue--2026-10-08 Thu #}' })
local tag = tag_at(3, 6)
tag:apply()
vim.wait(300, function() return vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1]:find('%-20 ') ~= nil end)
local written = vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1]:match('{@ date, (.-) @}'):gsub('%a%a%a ', 'DAY ')
check('handler writes the day back', written, '2026-10-20 DAY 10:00 +1w')
tag = tag_at(4, 5)
tag:apply()
vim.wait(300, function() return vim.api.nvim_buf_get_lines(buf, 3, 4, false)[1]:find('scheduled, 2026%-10%-20') ~= nil end)
local line4 = vim.api.nvim_buf_get_lines(buf, 3, 4, false)[1]
check('handler keeps the end of a range', line4:match('%-%-(%d%d%d%d%-%d%d%-%d%d)'), '2026-10-08')
check('handler moves the start of a range', line4:match('scheduled, (%d%d%d%d%-%d%d%-%d%d)'), '2026-10-20')

-- open at point reaches the handler
buf = buffer({ '  I. Head', '', '{@ date, 2026-10-06 Tue @}' })
vim.api.nvim_win_set_cursor(0, { 3, 5 })
require('fey.links').open_at_cursor(buf)
vim.wait(300, function() return vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1]:find('2026%-10%-20') ~= nil end)
check('open at point on a date', vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1]:find('2026%-10%-20') ~= nil, true)

if failures > 0 then
  print(('%d of %d checks failed'):format(failures, total))
  vim.cmd('cquit 1')
end
print(('ok: %d checks'):format(total))
vim.cmd('quit')
