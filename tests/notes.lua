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

print(('notes: %d checks, %d failures'):format(total, failures))
vim.cmd(failures == 0 and 'qa!' or 'cq!')
