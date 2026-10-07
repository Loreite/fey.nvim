-- Checkboxes and progress cookies. Run from the repo root:
--
--   FEY_PARSER=/path/to/fey.so nvim --headless --clean -l tests/checkbox.lua
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

local Checkbox = require('fey.files.elements.checkbox')

-- the rules --------------------------------------------------------------------------------------------------
check('classes', {
  Checkbox.class('[ ]'), Checkbox.class('[x]'), Checkbox.class('[X]'), Checkbox.class('[/]'), Checkbox.class('[-]'),
  Checkbox.class('[>]'), Checkbox.class('[!]'), Checkbox.class('[n]'), Checkbox.class('[?]'), Checkbox.class('[%]'), Checkbox.class('[`]'),
}, { 'open', 'done', 'done', 'active', 'cancelled', 'cancelled', 'open', 'info', 'open', 'active', 'open' })
check('progress counts tasks: notes and cancelled ones are left out', { Checkbox.progress({ '[x]', '[X]', '[/]', '[ ]', '[-]', '[n]', '[>]' }) }, { 2, 4 })
check('toggle', { Checkbox.next('toggle', '[ ]', {}), Checkbox.next('toggle', '[X]', {}), Checkbox.next('toggle', '[x]', {}), Checkbox.next('toggle', '[-]', {}), Checkbox.next('toggle', '[!]', {}) }, { '[X]', '[ ]', '[ ]', '[X]', '[X]' })
check('on, off and a given mark', { Checkbox.next('on', '[ ]', {}), Checkbox.next('off', '[X]', {}), Checkbox.next('mark:!', '[ ]', {}), Checkbox.next('mark:n', '[x]', {}) }, { '[X]', '[ ]', '[!]', '[n]' })
check('a parent follows its children', {
  Checkbox.next('children', '[ ]', { '[x]', '[X]' }),
  Checkbox.next('children', '[X]', { '[ ]', '[ ]' }),
  Checkbox.next('children', '[ ]', { '[x]', '[ ]' }),
  Checkbox.next('children', '[ ]', { '[/]', '[ ]' }),
  Checkbox.next('children', '[ ]', { '[x]', '[-]' }),
  Checkbox.next('children', '[!]', { '[n]', '[-]' }),
}, { '[X]', '[ ]', '[/]', '[/]', '[X]', '[!]' })
check('cookies keep their shape', { Checkbox.cookie('[0/3]', 2, 3), Checkbox.cookie('[0%]', 1, 3), Checkbox.cookie('[0%]', 0, 0), Checkbox.cookie('[1/1]', 0, 0) }, { '[2/3]', '[33%]', '[0%]', '[0/0]' })
check('what is a cookie', { Checkbox.is_cookie('[1/3]'), Checkbox.is_cookie('[50%]'), Checkbox.is_cookie('[ ]'), Checkbox.is_cookie('[x]') }, { true, true, false, false })

-- the states ------------------------------------------------------------------------------------------------
local seen, duplicates, wide, nerd_seen, nerd_dup = {}, {}, {}, {}, {}
for _, state in ipairs(Checkbox.STATES) do
  if seen[state.mark] then duplicates[#duplicates + 1] = state.mark end
  seen[state.mark] = true
  if vim.api.nvim_strwidth(state.unicode) ~= 1 then wide[#wide + 1] = state.mark end
  if state.mark ~= 'X' then
    if nerd_seen[state.nerd] then nerd_dup[#nerd_dup + 1] = state.mark end
    nerd_seen[state.nerd] = true
  end
end
check('no mark twice', duplicates, {})
check('every unicode icon is one cell wide', wide, {})
check('no two states share a glyph', nerd_dup, {})
local want_marks = { ' ', 'x', 'X', '.', ',', ':', ';', '!', '?', '-', '+', '*', '=', '~', '^', '@', '#', '$', '&', '%', '/', '>', '<', '"',
  'n', 'l', 'i', 'S', 'I', 'p', 'c', 'b', 'u', 'd', 'r', 'L', 't', 'T' }
local missing = {}
for _, mark in ipairs(want_marks) do
  if not seen[mark] then missing[#missing + 1] = mark end
end
check('every mark that was asked for has a state', missing, {})
check('a mark with no meaning is an open box', Checkbox.state_of_mark('Z').class, 'open')
check('icons', { Checkbox.icon('!', 'unicode'), Checkbox.icon('!', 'nerd') == vim.fn.nr2char(0xF06A), Checkbox.icon('x', 'unicode') }, { '‼', true, '☑' })

-- a buffer ----------------------------------------------------------------------------------------------------
local base = vim.uv.fs_realpath((function()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, 'p')
  return d
end)())
require('fey.config'):extend({ fey_court_dir = base .. '/court' })
local file = base .. '/list.fey'
vim.fn.mkdir(base .. '/.fey', 'p')
vim.fn.writefile({
  '  I. Shopping [0/2]',
  '',
  '-  [ ] Groceries [0/2]',
  '   -  [ ] milk',
  '   -  [ ] bread',
  '-  [ ] Tools',
  '-  plain item',
  '',
  '  II. Done so far [0%]',
  '',
  '-  [x] one',
  '-  [ ] two',
  '',
}, file)
vim.cmd('edit ' .. vim.fn.fnameescape(file))
vim.bo.filetype = 'fey'
local fey = require('fey').instance()
local function lines() return vim.api.nvim_buf_get_lines(0, 0, -1, false) end
local function toggle(row)
  vim.fn.cursor({ row, 5 })
  fey.fey_mappings:toggle_checkbox()
end

toggle(4)
check('a toggled item is done', lines()[4], '   -  [X] milk')
check('its parent is partly done, with its cookie', lines()[3], '-  [/] Groceries [1/2]')
check('the heading counts the top level items that are done', lines()[1], '  I. Shopping [0/2]')
toggle(5)
check('all children done: the parent is done', lines()[3], '-  [X] Groceries [2/2]')
check('and the heading follows', lines()[1], '  I. Shopping [1/2]')
toggle(6)
check('the last item done: the heading is complete', lines()[1], '  I. Shopping [2/2]')
toggle(6)
check('toggling back', { lines()[6], lines()[1] }, { '-  [ ] Tools', '  I. Shopping [1/2]' })
toggle(4)
check('unchecking a child makes the parent partly done again', { lines()[3], lines()[4] }, { '-  [/] Groceries [1/2]', '   -  [ ] milk' })
check('and the heading', lines()[1], '  I. Shopping [0/2]')

toggle(7)
check('an item without a box gets one when toggled', lines()[7], '-  [X] plain item')
check('and is counted', lines()[1], '  I. Shopping [1/3]')

toggle(12)
check('a percent cookie of a heading', { lines()[12], lines()[9] }, { '-  [X] two', '  II. Done so far [100%]' })
toggle(11)
check('and back down', lines()[9], '  II. Done so far [50%]')

-- the index ---------------------------------------------------------------------------------------------------
vim.cmd('silent write')
local registry = require('fey.vault')
local vault = registry.open(base)
local done = false
vault:scan({}, function() done = true end)
vim.wait(3000, function() return done end, 10)
local items = vault:tasks({ kind = 'item' })
check('the checkbox items are tasks of kind item', #items, 7)
check('with their mark and title', { items[1].title, items[1].state, items[1].done, items[1].kind }, { 'Groceries [1/2]', '/', false, 'item' })
check('done ones', #vim.tbl_filter(function(i) return i.done end, items), 3)
check('they are in the section that holds the list', items[1].heading_ord, 1)
check('and know its signature', items[1].signature, 'I.')
check('the default is the headings only', #vault:tasks(), 0)
check('both', #vault:tasks({ kind = 'all' }), 7)

local result = require('fey.api').vault(base):run_query('TASK WHERE kind = "item" AND !completed')
check('and there are open ones', #result.items > 0, true)
local done_items = require('fey.api').vault(base):run_query('TASK WHERE completed')
check('done items are completed tasks', #done_items.items, 3)
check('with the field checked', done_items.items[1].task.checked, true)

-- other marks in a file: the index and the rules ------------------------------------------------------------
vim.fn.writefile({
  '  I. Marks [0/2]',
  '',
  '-  [/] in progress',
  '-  [!] important',
  '-  [n] a note',
  '-  [-] cancelled',
  '-  [ ] open',
  '',
}, file)
vim.cmd('edit!')
vim.bo.filetype = 'fey'
vault:index_path(file)
local marks_rows = vault:tasks({ kind = 'item' })
check('every mark is indexed as written', vim.tbl_map(function(r) return r.state end, marks_rows), { '/', '!', 'n', '-', ' ' })
check('only the class done is done', vim.tbl_map(function(r) return r.done end, marks_rows), { false, false, false, false, false })
vim.fn.cursor({ 5, 5 })
fey.fey_mappings:toggle_checkbox()
check('a note toggled is done', lines()[5], '-  [X] a note')
check('and the heading counts it: notes and cancelled ones were not in the total', lines()[1], '  I. Marks [1/4]')
vim.fn.cursor({ 7, 5 })
local item = fey.files:get_closest_listitem()
item:update_checkbox('mark:?')
check('a given mark is written', lines()[7], '-  [?] open')

-- icons --------------------------------------------------------------------------------------------------------
local Icons = require('fey.colors.highlighter.checkbox_icons')
local ns2 = vim.api.nvim_create_namespace('fey_test_checkbox_icons')
local icons = Icons:new({ highlighter = { namespace = ns2 } })
icons.ephemeral = false
vim.fn.cursor({ 5, 5 })
fey.files:get_closest_listitem():update_checkbox('mark:n')
local tree2 = vim.treesitter.get_parser(0, 'fey'):parse()[1]
local buf2 = vim.api.nvim_get_current_buf()
local function icon_marks(row)
  vim.api.nvim_buf_clear_namespace(buf2, ns2, 0, -1)
  icons:on_line(buf2, row, tree2)
  local out = {}
  local line = vim.api.nvim_buf_get_lines(buf2, row, row + 1, false)[1]
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf2, ns2, { row, 0 }, { row, -1 }, { details = true })) do
    local d = m[4]
    out[#out + 1] = { hidden = line:sub(m[3] + 1, d.end_col), icon = d.conceal, face = d.hl_group }
  end
  return out
end
conf = require('fey.config')
conf:extend({ fey_checkbox_icons = 'unicode' })
vim.fn.cursor({ 1, 1 })
local m3 = icon_marks(2)
check('the box is hidden and its icon shown in the colour of its class', m3, { { hidden = '[', icon = '◐', face = '@fey.checkbox.active' }, { hidden = '/]', icon = '' } })
check('an important mark', icon_marks(3)[1].icon, '‼')
check('a note is an info face', icon_marks(4)[1].face, '@fey.checkbox.info')
check('a cancelled item', icon_marks(5)[1].face, '@fey.checkbox.cancelled')
conf:extend({ fey_checkbox_icons = 'nerd' })
check('nerd glyphs', icon_marks(3)[1].icon, vim.fn.nr2char(0xF06A))
conf:extend({ fey_checkbox_icon_overrides = { ['!'] = 'Z' } })
check('a mark can be given another icon', icon_marks(3)[1].icon, 'Z')
conf:extend({ fey_checkbox_icon_overrides = {} })
vim.fn.cursor({ 3, 1 })
check('the line of the cursor shows the box as written', icon_marks(2), {})
vim.fn.cursor({ 1, 1 })
conf:extend({ fey_show_checkbox_state_as_icons = false })
check('switched off in the configuration', icon_marks(2), {})
vim.b[buf2].fey_show_checkbox_state_as_icons = true
check('and on again for one buffer', #icon_marks(2), 2)
vim.b[buf2].fey_show_checkbox_state_as_icons = nil
conf:extend({ fey_show_checkbox_state_as_icons = true, fey_checkbox_icons = 'auto' })
check('auto picks an icon set', Icons.style() == 'nerd' or Icons.style() == 'unicode', true)

-- the highlight query still loads, and marks the boxes
vim.cmd('silent! write')
vim.cmd('edit! ' .. vim.fn.fnameescape(file))
vim.bo.filetype = 'fey'
local ok_q, hl = pcall(vim.treesitter.query.get, 'fey', 'highlights')
check('the highlights query loads', ok_q and hl ~= nil, true)
local names = {}
vim.cmd('edit! ' .. vim.fn.fnameescape(file))
vim.fn.writefile({ '-  [x] a', '-  [/] b', '-  [ ] c', '' }, file)
vim.cmd('edit!')
if ok_q and hl then
  local tree = vim.treesitter.get_parser(0, 'fey'):parse()[1]
  for id, node in hl:iter_captures(tree:root(), 0) do
    if hl.captures[id]:find('checkbox', 1, true) then names[hl.captures[id]] = true end
  end
end
check('boxes are highlighted, done ones apart', { names['fey.checkbox'], names['fey.checkbox.checked'], names['fey.checkbox.halfchecked'] }, { true, true, true })

-- the mapping
local conf = require('fey.config')
conf:extend({ mappings = { prefix = '<Space>' } })
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf)
conf:setup_mappings('fey', buf)
check('<C-Space> toggles', vim.fn.maparg('<C-Space>', 'n', false, true).buffer, 1)
check('<prefix>sc picks a state', vim.fn.maparg('<Space>sc', 'n', false, true).buffer, 1)

if failures > 0 then
  print(('%d of %d checks failed'):format(failures, total))
  vim.cmd('cquit 1')
end
print(('ok: %d checks'):format(total))
vim.cmd('qa!')
