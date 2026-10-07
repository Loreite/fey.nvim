-- Drawers and notes. Run from the repo root:
--
--   FEY_PARSER=/path/to/fey.so nvim --headless --clean -l tests/notes.lua
vim.opt.rtp:prepend('.')
if vim.env.FEY_PARSER then vim.treesitter.language.add('fey', { path = vim.env.FEY_PARSER }) end
local config = require('fey.config')
config:extend({})
config:setup_ts_predicates()

local FeyFile = require('fey.files.file')
local Tag = require('fey.files.elements.tags')
Tag.setup({})

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
local function open(text)
  n = n + 1
  local name = ('%s/t%d.fey'):format(dir, n)
  vim.fn.writefile(text, name)
  vim.cmd('edit ' .. vim.fn.fnameescape(name))
  local buf = vim.api.nvim_get_current_buf()
  vim.b[buf].did_ftplugin = true
  vim.bo[buf].filetype = 'fey'
  vim.treesitter.start(buf, 'fey')
  return buf, FeyFile:new({ filename = name, buf = buf })
end
local function lines(buf) return vim.api.nvim_buf_get_lines(buf, 0, -1, false) end
local function parses(buf)
  local tree = vim.treesitter.get_parser(buf, 'fey'):parse(true)[1]
  return not tree:root():has_error()
end

-- notes outside a drawer ----------------------------------------------------------
local buf, file = open({ '  I. Head', '', 'text', '' })
local h = file:get_closest_heading({ 1, 0 })
check('no drawer yet', h:get_drawer('LOGBOOK') == nil, true)
config:extend({ fey_log_into_logbook = false })
h:add_note({ '-  note one' })
check('note goes under the heading', lines(buf)[#lines(buf)] ~= nil and table.concat(lines(buf), '\n'):find('note one', 1, true) ~= nil, true)

-- notes in the logbook ------------------------------------------------------------
buf, file = open({ '  I. Head {# status, TODO #}', '', 'text', '', '  II. Other', '' })
config:extend({ fey_log_into_logbook = true })
h = file:get_closest_heading({ 1, 0 })
h:add_note({ '-  {@ date, 2026-10-06 Tue 09:00; active: false @}  Note taken: first', '   second line' })
local l = lines(buf)
check('logbook created', vim.tbl_contains(l, '[ logbook #]') or vim.tbl_contains(l, '[ LOGBOOK #]'), true)
check('buffer parses', parses(buf), true)
check('drawer found', h:get_drawer(config.fey_logbook_tag_name or 'logbook') ~= nil, true)
h:add_note({ '-  {@ date, 2026-10-07 Wed 10:00; active: false @}  Note taken: newest' })
l = lines(buf)
local first, second
for i, line in ipairs(l) do
  if line:find('newest', 1, true) then first = i end
  if line:find('first', 1, true) then second = i end
end
check('newest note first', first ~= nil and second ~= nil and first < second, true)
check('still parses', parses(buf), true)
check('other heading untouched', l[#l - 1], '  II. Other')
check('single logbook', #vim.tbl_filter(function(x) return x:match('^%[ ' .. config.fey_logbook_tag_name .. ' #%]$') end, l), 1)

-- the format of a note from the mapping --------------------------------------------
config:extend({ fey_log_into_logbook = false })
buf, file = open({ '  I. Head', '', 'text', '' })
vim.api.nvim_win_set_cursor(0, { 1, 0 })
local Mappings = require('fey.fey.mappings')
local capture = { build_note_capture = function() return { open = function() return require('fey.utils.promise').resolve({ 'hello', 'more' }) end } end }
local fake = setmetatable({ capture = capture, files = { get_closest_heading = function() return file:get_closest_heading({ 1, 0 }) end } }, { __index = Mappings })
local ok, err = pcall(function() fake:add_note():wait() end)
check('add_note runs ' .. tostring(err), ok, true)
l = lines(buf)
local joined = table.concat(l, '\n')
check('note head', joined:match('%-  {@ date, [^\n]-active: false @}  Note taken: hello') ~= nil, true)
check('continuation indented', joined:find('\n   more', 1, true) ~= nil, true)
check('parses with note', parses(buf), true)


-- block tag drawers -----------------------------------------------------------------
config:extend({ fey_log_into_logbook = true, fey_drawer_form = 'pair' })
buf, file = open({
  '  I. Head {# status, TODO #}',
  '',
  '[ logbook ]#',
  '   -  {@ date, 2026-10-06 Tue 09:00; active: false @}  Note taken: old',
  '',
  'text',
  '',
})
h = file:get_closest_heading({ 1, 0 })
check('block drawer found', h:get_drawer('logbook') ~= nil and h:get_drawer('logbook'):type(), 'block_tag')
h:add_note({ '-  {@ date, 2026-10-07 Wed 10:00; active: false @}  Note taken: new', '   more' })
l = lines(buf)
check('note indented into the block', { l[4], l[5] }, { '   -  {@ date, 2026-10-07 Wed 10:00; active: false @}  Note taken: new', '      more' })
check('old note kept', l[6]:find('old', 1, true) ~= nil, true)
check('block parses', parses(buf), true)
check('no second drawer', #vim.tbl_filter(function(x) return x:find('logbook', 1, true) and not x:find('Note') end, l), 1)

-- a clock in a block logbook
local Logbook = require('fey.files.elements.logbook')
buf, file = open({ '  I. Head', '', '[ logbook ]#', '   {# clock, 2026-10-06 Tue 10:00 #}', '', 'text', '' })
h = file:get_closest_heading({ 1, 0 })
local lb = Logbook.from_heading(h)
check('block logbook read', { lb ~= nil, lb and #lb.items, lb and lb.indent, lb and lb.range.start_line, lb and lb.range.end_line }, { true, 1, '   ', 3, 4 })
check('the clock runs', lb:is_active(), true)
Logbook.clock_out(h)
l = lines(buf)
check('clock out keeps the indent', l[4]:match('^   {# clock, 2026%-10%-06 Tue 10:00; end:') ~= nil, true)
Logbook.add_clock_in(h)
l = lines(buf)
check('clock in goes inside the block', { l[3], l[4]:match('^   {# clock') ~= nil }, { '[ logbook ]#', true })
check('logbook block still parses', parses(buf), true)

-- a new drawer in the block form
config:extend({ fey_drawer_form = 'block' })
buf, file = open({ '  I. Head', '', 'text', '' })
h = file:get_closest_heading({ 1, 0 })
h:add_note({ '-  {@ date, 2026-10-07 Wed 10:00; active: false @}  Note taken: fresh' })
l = lines(buf)
check('new drawer is a block', { l[2], l[3] }, { '[ logbook ]#', '   -  {@ date, 2026-10-07 Wed 10:00; active: false @}  Note taken: fresh' })
check('new block parses', parses(buf), true)
Logbook.add_clock_in(h)
check('clock joins the new block', Logbook.from_heading(h):is_active(), true)
buf, file = open({ '  I. Head', '', 'text', '' })
Logbook.add_clock_in(file:get_closest_heading({ 1, 0 }))
l = lines(buf)
check('a new logbook in the block form', { l[2], l[3]:match('^   {# clock') ~= nil }, { '[ logbook ]#', true })
check('and it parses', parses(buf), true)
config:extend({ fey_drawer_form = 'pair' })

-- the document drawer in a block form
buf, file = open({ '[ logbook ]#', '   -  x', '', '  I. Head', '' })
check('document drawer as a block', file:get_drawer('logbook') ~= nil and file:get_drawer('logbook'):type(), 'block_tag')

print(('notes: %d checks, %d failures'):format(total, failures))
vim.cmd(failures == 0 and 'qa!' or 'cq!')
