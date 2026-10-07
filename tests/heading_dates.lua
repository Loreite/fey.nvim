-- Tests of planning dates on headings and of the date mappings. Run from the repo root:
--
--   FEY_PARSER=/path/to/fey.so nvim --headless --clean -l tests/heading_dates.lua
vim.opt.rtp:prepend('.')
if vim.env.FEY_PARSER then vim.treesitter.language.add('fey', { path = vim.env.FEY_PARSER }) end
require('fey.config'):extend({})

local Date = require('fey.objects.date')
local FeyFile = require('fey.files.file')

local failures, total = 0, 0
local function check(name, got, want)
  total = total + 1
  if not vim.deep_equal(got, want) then
    failures = failures + 1
    print(('FAIL %s\n  got:  %s\n  want: %s'):format(name, vim.inspect(got), vim.inspect(want)))
  end
end

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, 'p')
local n = 0
---@return integer buf, FeyFile file
local function open(lines)
  n = n + 1
  local name = ('%s/t%d.fey'):format(dir, n)
  vim.fn.writefile(lines, name)
  vim.cmd('edit ' .. vim.fn.fnameescape(name))
  local buf = vim.api.nvim_get_current_buf()
  vim.b[buf].did_ftplugin = true
  vim.bo[buf].filetype = 'fey'
  vim.treesitter.start(buf, 'fey')
  return buf, FeyFile:new({ filename = name, buf = buf })
end
local function lines(buf) return vim.api.nvim_buf_get_lines(buf, 0, -1, false) end
local function day(s) return Date.from_string(s, { active = true }) end

-- reading -----------------------------------------------------------------------
local buf, file = open({
  '  I. Write {# todo, TODO #} the report',
  '{# scheduled, 2026-10-06 Tue 10:00 +1w #} {# deadline, 2026-10-10 Sat #}',
  '',
  'Meet on {@ date, 2026-10-08 Thu 14:00 @}.',
  '',
  '  I.A. Child',
  '{# closed, 2026-10-01 Thu #}',
  '',
})
local h = file:get_closest_heading({ 1, 0 })
local plan, nodes, has = h:get_planning_dates()
check('has plan dates', has, true)
check('scheduled', plan.SCHEDULED[1]:to_tag_value(), '2026-10-06 Tue 10:00 +1w')
check('deadline', plan.DEADLINE[1]:to_tag_value(), '2026-10-10 Sat')
check('no closed', plan.CLOSED, nil)
check('plan nodes', nodes.SCHEDULED:type(), 'scope_tag')
check('get_scheduled_date', h:get_scheduled_date().day, 6)
check('get_deadline_date', h:get_deadline_date().day, 10)
check('non plan dates', vim.tbl_map(function(d) return d.day end, h:get_non_planning_dates()), { 8 })
check('all dates', #h:get_all_dates(), 3)
check('plan dates are typed', { h:get_scheduled_date().type, h:get_deadline_date().type }, { 'SCHEDULED', 'DEADLINE' })
local child = file:get_closest_heading({ 6, 0 })
check('closed date', child:get_closed_date().day, 1)
check('closed is inactive', child:get_closed_date().active, false)
check('agenda dates skip a closed one', #child:get_valid_dates_for_agenda(), 0)
check('append line after the region', h:get_append_line(), 2)
check('append line of a heading without a region', file:get_closest_heading({ 6, 0 }):get_append_line(), 7)

-- writing -----------------------------------------------------------------------
buf, file = open({ '  I. Head', '', 'Text.', '' })
h = file:get_closest_heading({ 1, 0 })
h:set_scheduled_date(day('2026-10-06 Tue'))
check('first planning date gets a line', lines(buf)[2], '{# scheduled, 2026-10-06 Tue #}')
check('text stays below', lines(buf)[3], '')
h = file:get_closest_heading({ 1, 0 })
h:set_deadline_date(day('2026-10-10 Sat'))
check('next planning date joins the line', lines(buf)[2], '{# scheduled, 2026-10-06 Tue #} {# deadline, 2026-10-10 Sat #}')
h = file:get_closest_heading({ 1, 0 })
h:set_scheduled_date(day('2026-10-07 Wed 09:30'))
check('a planning date is replaced', lines(buf)[2], '{# scheduled, 2026-10-07 Wed 09:30 #} {# deadline, 2026-10-10 Sat #}')
h = file:get_closest_heading({ 1, 0 })
h:set_closed_date(day('2026-10-11 Sun'))
check('closed is written inactive', lines(buf)[2]:match('{# closed, [^#]-#}'), '{# closed, 2026-10-11 Sun #}')
h = file:get_closest_heading({ 1, 0 })
check('closed round trip', h:get_closed_date().active, false)
h:remove_scheduled_date()
check('removing one of several', lines(buf)[2], '{# deadline, 2026-10-10 Sat #} {# closed, 2026-10-11 Sun #}')
h = file:get_closest_heading({ 1, 0 })
h:remove_closed_date()
h = file:get_closest_heading({ 1, 0 })
h:remove_deadline_date()
check('removing the last one removes the line', { lines(buf)[1], lines(buf)[2], lines(buf)[3] }, { '  I. Head', '', 'Text.' })

-- a planning tag in the title is found and edited in place
buf, file = open({ '  I. Head {# deadline, 2026-10-10 Sat #}', '' })
h = file:get_closest_heading({ 1, 0 })
check('planning tag in the title', h:get_deadline_date().day, 10)
h:set_deadline_date(day('2026-10-12 Mon'))
check('title planning tag replaced', lines(buf)[1], '  I. Head {# deadline, 2026-10-12 Mon #}')

-- mappings on the date under the cursor ------------------------------------------
local FeyMappings = require('fey.fey.mappings')
local mappings = setmetatable({}, { __index = FeyMappings })
buf, file = open({ '  I. Head', '', 'a {@ date, 2026-10-06 Tue 10:00 +1w @} b', '{@ date, 2026-10-06 Tue--2026-10-08 Thu @}', '{# closed, 2026-10-09 Fri #}', '' })
vim.api.nvim_win_set_cursor(0, { 3, 8 })
mappings:_adjust_date(1, 'd', '')
check('adjust a day', lines(buf)[3], 'a {@ date, 2026-10-07 Wed 10:00 +1w @} b')
vim.api.nvim_win_set_cursor(0, { 3, 8 })
mappings:_adjust_date(-2, 'd', '')
check('adjust back', lines(buf)[3], 'a {@ date, 2026-10-05 Mon 10:00 +1w @} b')

vim.api.nvim_win_set_cursor(0, { 3, 8 })
mappings:fey_toggle_date_type()
check('toggle to inactive', lines(buf)[3], 'a {@ date, 2026-10-05 Mon 10:00 +1w; active: false @} b')
vim.api.nvim_win_set_cursor(0, { 3, 8 })
mappings:fey_toggle_date_type()
check('toggle back to active', lines(buf)[3], 'a {@ date, 2026-10-05 Mon 10:00 +1w @} b')

-- on the end of a range
vim.api.nvim_win_set_cursor(0, { 4, 30 })
mappings:_adjust_date(1, 'd', '')
check('adjust the end of a range', lines(buf)[4], '{@ date, 2026-10-06 Tue--2026-10-09 Fri @}')
vim.api.nvim_win_set_cursor(0, { 4, 14 })
mappings:_adjust_date(1, 'd', '')
check('adjust the start of a range', lines(buf)[4], '{@ date, 2026-10-07 Wed--2026-10-09 Fri @}')

-- a closed date toggles to active with an explicit key
vim.api.nvim_win_set_cursor(0, { 5, 5 })
mappings:fey_toggle_date_type()
check('closed becomes active', lines(buf)[5], '{# closed, 2026-10-09 Fri; active: true #}')
vim.api.nvim_win_set_cursor(0, { 5, 5 })
mappings:fey_toggle_date_type()
check('closed becomes inactive again', lines(buf)[5], '{# closed, 2026-10-09 Fri #}')

-- the part under the cursor
vim.api.nvim_win_set_cursor(0, { 3, 1 })
vim.cmd('normal! 0')
local line3 = lines(buf)[3]
vim.api.nvim_win_set_cursor(0, { 3, line3:find('2026') - 1 }) -- on the year
mappings:_adjust_date_part('+', 1, '')
check('adjust the year part', lines(buf)[3], 'a {@ date, 2027-10-05 Tue 10:00 +1w @} b')

-- no date: a key falls through
local fed
local feedkeys = vim.api.nvim_feedkeys
vim.api.nvim_feedkeys = function(keys) fed = keys end
vim.api.nvim_win_set_cursor(0, { 3, 0 })
mappings:_adjust_date(1, 'd', 'FALLBACK')
vim.api.nvim_feedkeys = feedkeys
check('no date under the cursor falls back', fed, 'FALLBACK')

if failures > 0 then
  print(('%d of %d checks failed'):format(failures, total))
  vim.cmd('cquit 1')
end
print(('ok: %d checks'):format(total))
vim.cmd('qa!')
