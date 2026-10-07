-- Footnotes as tags. Run from the repo root:
--
--   FEY_PARSER=/path/to/fey.so nvim --headless --clean -l tests/footnotes.lua
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
vim.fn.mkdir(base .. '/.fey', 'p')
local file = base .. '/notes.fey'
local function write(lines) vim.fn.writefile(lines, file) end
local function lines() return vim.api.nvim_buf_get_lines(0, 0, -1, false) end
local function open(text)
  write(text)
  vim.cmd('edit! ' .. vim.fn.fnameescape(file))
  vim.bo.filetype = 'fey'
end
local F = require('fey.footnotes')
local Tag = require('fey.files.elements.tags')
Tag.setup({})

write({
  '  I. Head',
  '',
  'The result is odd {@ fn, 1 @} and so is this {@ fn, note @}.',
  '',
  '[ fn, 1 #]',
  'Measured twice.',
  '[# fn ]',
  '',
  '  II. Next',
  '',
  'Again {@ fn, 1 @}, and one with no definition {@ fn, gone @}.',
  '',
  '[ fn, unused #]',
  'Nobody refers to me.',
  '[# fn ]',
  '',
})
vim.cmd('edit! ' .. vim.fn.fnameescape(file))
vim.bo.filetype = 'fey'

-- reading -----------------------------------------------------------------------------------------------------
local tags = F.scan()
check('every footnote tag is found, in order', vim.tbl_map(function(t) return (t.is_reference and 'ref:' or 'def:') .. t.label end, tags), { 'ref:1', 'ref:note', 'def:1', 'ref:1', 'ref:gone', 'def:unused' })
check('find a definition', F.find('1', false).row, 4)
check('find the first reference', { F.find('1', true).row, F.find('1', true).col }, { 2, 18 })
check('none', F.find('nope', false), nil)
check('the next free label', F.next_label(), '2')

-- the cursor --------------------------------------------------------------------------------------------------
vim.api.nvim_win_set_cursor(0, { 3, 20 })
check('a reference under the cursor', F.at_cursor() and { F.at_cursor().label, F.at_cursor().is_reference }, { '1', true })
vim.api.nvim_win_set_cursor(0, { 3, 5 })
check('plain text is not a footnote', F.at_cursor(), nil)
vim.api.nvim_win_set_cursor(0, { 5, 2 })
check('the opening line of a definition', F.at_cursor() and { F.at_cursor().label, F.at_cursor().is_reference }, { '1', false })
vim.api.nvim_win_set_cursor(0, { 6, 2 })
check('its text is not the tag', F.at_cursor(), nil)

-- open at point ----------------------------------------------------------------------------------------------
vim.api.nvim_win_set_cursor(0, { 3, 20 })
require('fey.links').open_at_cursor()
check('a reference jumps to the text of its definition', vim.api.nvim_win_get_cursor(0)[1], 6)
vim.api.nvim_win_set_cursor(0, { 5, 2 })
require('fey.links').open_at_cursor()
check('a definition jumps back to the first reference', vim.api.nvim_win_get_cursor(0), { 3, 18 })
vim.api.nvim_win_set_cursor(0, { 11, 10 })
require('fey.links').open_at_cursor()
check('the second reference too reaches the definition', vim.api.nvim_win_get_cursor(0)[1], 6)

-- a missing definition is offered ---------------------------------------------------------------------------
local confirms = 0
local real_confirm = vim.fn.confirm
vim.fn.confirm = function() confirms = confirms + 1 return 1 end
vim.api.nvim_win_set_cursor(0, { 11, 55 })
local before = #lines()
require('fey.links').open_at_cursor()
vim.fn.confirm = real_confirm
check('it asked', confirms, 1)
check('a definition was added at the end', { #lines() - before, lines()[#lines() - 2], lines()[#lines()] }, { 3, '[ fn, gone #]', '[# fn ]' })
check('the cursor is in its text', vim.api.nvim_win_get_cursor(0)[1], #lines() - 1)
vim.cmd('stopinsert')

-- line and block definitions --------------------------------------------------------------------------------
open({
  '  I. Head',
  '',
  'Pair {@ fn, 1 @}, line {@ fn, 2 @}, block {@ fn, 3 @}.',
  '',
  '[ fn, 1 #]',
  'Pair text.',
  '[# fn ]',
  '',
  '#[ fn, 2 ] Line text. #',
  '',
  '[ fn, 3 ]#',
  '    Block text.',
  '',
  'After.',
  '',
})
local forms = vim.tbl_map(function(t) return t.label .. ':' .. t.form end, F.scan())
check('every form is found', forms, { '1:scope', '2:scope', '3:scope', '1:pair', '2:line', '3:block' })
check('a definition is any form but the scope', vim.tbl_map(function(t) return t.is_reference end, F.scan()), { true, true, true, false, false, false })
check('a line definition is found as a definition', F.find('2', false).form, 'line')
check('a block definition too', F.find('3', false).form, 'block')

vim.api.nvim_win_set_cursor(0, { 3, 25 })
require('fey.links').open_at_cursor()
check('a reference jumps to the text of a line definition', vim.api.nvim_win_get_cursor(0), { 9, 11 })
vim.api.nvim_win_set_cursor(0, { 3, 45 })
require('fey.links').open_at_cursor()
check('and to the text of a block definition', vim.api.nvim_win_get_cursor(0)[1], 12)

vim.api.nvim_win_set_cursor(0, { 9, 4 })
check('the cursor on a line definition', F.at_cursor() and F.at_cursor().form, 'line')
require('fey.links').open_at_cursor()
check('a line definition jumps back to the reference', vim.api.nvim_win_get_cursor(0), { 3, 23 })
vim.api.nvim_win_set_cursor(0, { 11, 2 })
check('the opening line of a block definition', F.at_cursor() and F.at_cursor().form, 'block')
require('fey.links').open_at_cursor()
check('a block definition jumps back to the reference', vim.api.nvim_win_get_cursor(0)[1], 3)
vim.api.nvim_win_set_cursor(0, { 12, 6 })
check('the text of a block is not the tag', F.at_cursor(), nil)

-- new definitions in the form that is configured ------------------------------------------------------------
local conf = require('fey.config')
for _, case in ipairs({
  { 'line', { '', '#[ fn, 1 ] #' } },
  { 'block', { '', '[ fn, 1 ]#', '    ' } },
  { 'pair', { '', '[ fn, 1 #]', '', '[# fn ]' } },
}) do
  conf:extend({ fey_footnote_definition_form = case[1] })
  open({ '  I. Head', '', 'Text.', '' })
  vim.api.nvim_win_set_cursor(0, { 3, 1 })
  F.insert()
  vim.cmd('stopinsert')
  local out = lines()
  local tail = vim.list_slice(out, #out - #case[2] + 1)
  check('a new definition in the ' .. case[1] .. ' form', tail, case[2])
  check('and the next label sees it', F.next_label(), '2')
  check('it is a definition of its label', F.find('1', false) and F.find('1', false).form, case[1])
end
conf:extend({ fey_footnote_definition_form = 'pair' })

-- insert a footnote ---------------------------------------------------------------------------------------------
open({ '  I. Head', '', 'A sentence.', '' })
vim.api.nvim_win_set_cursor(0, { 3, 7 })
F.insert()
vim.cmd('stopinsert')
local got = lines()
check('with the next label', got[3]:find('{@ fn, 1 @}', 1, true) ~= nil, true)
check('and a definition at the end, empty, closed', { got[#got - 2], got[#got - 1], got[#got] }, { '[ fn, 1 #]', '', '[# fn ]' })
check('a blank line before it', got[#got - 3], '')
vim.api.nvim_win_set_cursor(0, { 3, 1 })
F.insert()
vim.cmd('stopinsert')
check('the next one takes the next label', F.next_label(), '3')

-- under a Footnotes heading --------------------------------------------------------------------------------------
open({ '  I. Text', '', 'A claim.', '', '  II. Footnotes', '', '  III. After', '' })
vim.api.nvim_win_set_cursor(0, { 3, 1 })
F.insert()
vim.cmd('stopinsert')
got = lines()
local def_at
for i, l in ipairs(got) do
  if l == '[ fn, 1 #]' then def_at = i end
end
check('the definition goes under the heading Footnotes', def_at ~= nil and def_at > 5 and def_at < #got - 2, true)
check('and before the next heading', (function()
  for i, l in ipairs(got) do
    if l:find('III. After', 1, true) then return i > def_at end
  end
end)(), true)

-- the index ----------------------------------------------------------------------------------------------------
write({
  '  I. Head',
  '',
  'Odd {@ fn, 1 @} and {@ fn, 1 @} and {@ fn, gone @}.',
  '',
  '[ fn, 1 #]',
  'Measured twice.',
  '[# fn ]',
  '',
  '[ fn, unused #]',
  'x',
  '[# fn ]',
  '',
  'Line {@ fn, l @} block {@ fn, b @}.',
  '',
  '#[ fn, l ] line text #',
  '',
  '[ fn, b ]#',
  '    block text',
  '',
})
local vault = require('fey.vault').open(base)
local done = false
vault:scan({}, function() done = true end)
vim.wait(3000, function() return done end, 10)
local rows = vault:footnotes()
check('a row per label', vim.tbl_map(function(r) return r.label end, rows), { '1', 'gone', 'unused', 'l', 'b' })
check('line and block definitions count as definitions', vim.tbl_map(function(r) return r.defined end, rows), { true, false, true, true, true })
check('references and definition', { rows[1].references, rows[1].defined, rows[1].line, rows[1].definition_line }, { 2, true, 3, 5 })
check('a missing definition is a query', vim.tbl_map(function(r) return r.label end, vault:footnotes({ missing = true })), { 'gone' })
check('and an unused one', vim.tbl_map(function(r) return r.label end, vault:footnotes({ unused = true })), { 'unused' })
check('the API has it', #require('fey.api').vault(base):footnotes(), 5)

-- superscript ---------------------------------------------------------------------------------------------------
local Superscript = require('fey.footnotes.superscript')
check('digits are superscript in auto', { Superscript.convert('1', 'auto'), Superscript.convert('12', 'auto'), Superscript.convert('0-9', 'auto') }, { '¹', '¹²', '⁰⁻⁹' })
check('letters need the setting', { Superscript.convert('note', 'auto'), Superscript.convert('note', true) }, { nil, 'ⁿᵒᵗᵉ' })
check('a label that cannot be written whole stays', { Superscript.convert('q', true), Superscript.convert('1q', true) }, { nil, nil })
check('off', Superscript.convert('1', false), nil)

local Marks = require('fey.colors.highlighter.footnote_marks')
open({
  '  I. Head',
  '',
  'A {@ fn, 12 @} and {@ fn, note @}.',
  '',
  '[ fn, 12 #]',
  'Pair text.',
  '[# fn ]',
  '',
  '#[ fn, 12 ] Line text. #',
  '',
  '[ fn, 12 ]#',
  '    Block text.',
  '',
})
local ns3 = vim.api.nvim_create_namespace('fey_test_footnote_marks')
local marks_hl = Marks:new({ highlighter = { namespace = ns3 } })
marks_hl.ephemeral = false
local tree3 = vim.treesitter.get_parser(0, 'fey'):parse()[1]
local buf3 = vim.api.nvim_get_current_buf()
vim.api.nvim_win_set_cursor(0, { 1, 0 })
local function shown(row)
  vim.api.nvim_buf_clear_namespace(buf3, ns3, 0, -1)
  marks_hl:on_line(buf3, row, tree3)
  local out = ''
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf3, ns3, { row, 0 }, { row, -1 }, { details = true })) do
    out = out .. (m[4].conceal or '')
  end
  return out, #vim.api.nvim_buf_get_extmarks(buf3, ns3, { row, 0 }, { row, -1 }, {})
end
check('a reference shows its label as superscript, a label of letters stays as written', (shown(2)), '¹²')
check('the pair head', (shown(4)), '¹²')
local closer_text, closer_marks = shown(6)
check('the pair closer is hidden', { closer_text, closer_marks > 0 }, { '', true })
check('the line tag head and its closing hash', (shown(8)), '¹²')
check('the block head', (shown(10)), '¹²')
check('the text of a definition is untouched', { shown(5) }, { '', 0 })
vim.api.nvim_win_set_cursor(0, { 3, 0 })
check('the line of the cursor shows the tags as written', { shown(2) }, { '', 0 })
vim.api.nvim_win_set_cursor(0, { 1, 0 })
conf:extend({ fey_footnote_superscript = true })
check('letters with the setting on', (shown(2)), '¹²ⁿᵒᵗᵉ')
conf:extend({ fey_footnote_superscript = false })
check('and nothing when it is off', { shown(2) }, { '', 0 })
vim.b[buf3].fey_footnote_superscript = 'auto'
check('on for one buffer', (shown(2)), '¹²')
vim.b[buf3].fey_footnote_superscript = nil
conf:extend({ fey_footnote_superscript = 'auto' })

-- the mapping
local conf = require('fey.config')
conf:extend({ mappings = { prefix = '<Space>' } })
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf)
conf:setup_mappings('fey', buf)
check('<prefix>nf inserts a footnote', vim.fn.maparg('<Space>nf', 'n', false, true).buffer, 1)
check('open at point applies the handler', Tag.at_point[conf.fey_footnote_tag_name], true)

if failures > 0 then
  print(('%d of %d checks failed'):format(failures, total))
  vim.cmd('cquit 1')
end
print(('ok: %d checks'):format(total))
vim.cmd('qa!')
