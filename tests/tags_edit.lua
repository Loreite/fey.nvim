-- Tests of the tag toolkit (fey.files.elements.tags.edit). Run from the repo root:
--
--   FEY_PARSER=/path/to/fey.so nvim --headless --clean -l tests/tags_edit.lua
vim.opt.rtp:prepend('.')
if vim.env.FEY_PARSER then vim.treesitter.language.add('fey', { path = vim.env.FEY_PARSER }) end
require('fey.config'):extend({})

local edit = require('fey.files.elements.tags.edit')
local Tag = require('fey.files.elements.tags')

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

local function lines(buf) return vim.api.nvim_buf_get_lines(buf, 0, -1, false) end
local function names(tags) return vim.tbl_map(function(t) return t.name end, tags) end

---re-read the tag at a position after an edit
local function tag_at(buf, row, col)
  vim.api.nvim_win_set_cursor(0, { row, col })
  return edit.at_cursor(buf)
end

-- at_cursor -------------------------------------------------------------------
local buf = buffer({ '  I. Head', '', 'a {# x, 1 #} b {# y; k: v #}' })
check('at_cursor inside', (tag_at(buf, 3, 6) or {}).name, 'x')
check('at_cursor second tag', (tag_at(buf, 3, 20) or {}).name, 'y')
check('at_cursor outside', tag_at(buf, 3, 0), nil)
vim.api.nvim_win_set_cursor(0, { 3, 0 })
check('at_cursor line fallback', (edit.at_cursor(buf, { line = true }) or {}).name, 'x')
check('at_cursor name filter', (edit.at_cursor(buf, { line = true, name = 'y' }) or {}).name, 'y')

-- for_heading -----------------------------------------------------------------
buf = buffer({
  '  I. {# todo, TODO #} Write {# labels, a, b #}',
  '{# scheduled, 2026-10-06 #}',
  '',
  '{# prop; effort: 2h #} {# deadline, 2026-10-07 #}',
  '{# closed, 2026-10-08 #}',
  'Text with {# inline, x #} in it.',
  '{# late, x #}',
  '',
  '  I.A. Child',
  '{# prop; z: 1 #} text after the tag',
  '',
})
local root = vim.treesitter.get_parser(buf, 'fey'):parse()[1]:root()
local first = root:field('subsection')[1]
local tags, last_row = edit.for_heading(buf, first)
check('region names', names(tags), { 'todo', 'labels', 'scheduled', 'prop', 'deadline', 'closed' })
check('region parts', vim.tbl_map(function(t) return t.region end, tags), { 'title', 'title', 'body', 'body', 'body', 'body' })
check('region last row', last_row, 4)
check('region filter', names((edit.for_heading(buf, first, { name = 'prop' }))), { 'prop' })
check('region key values', tags[4].key_values, { effort = '2h' })
local child = first:field('subsection')[1]
check('tag sharing its line with text is not metadata', names((edit.for_heading(buf, child))), {})

-- build -----------------------------------------------------------------------
check('build', edit.build('todo', { 'TODO' }), '{# todo, TODO #}')
check('build keys', edit.build('prop', {}, { b = '2', a = '1' }), '{# prop; a: 1; b: 2 #}')
check('build order', edit.build('prop', { 'v' }, { b = '2', a = '1' }, { order = { 'b', 'a' } }), '{# prop, v; b: 2; a: 1 #}')
check('build escapes', edit.build('t', { 'a,b;c\\d' }), '{# t, a\\,b\\;c\\\\d #}')
check('build bracket', edit.build('date', { '2026-10-06' }, nil, { sigil = '@', bracket = '[' }), '[@ date, 2026-10-06 @]')
check('build rejects an end', (edit.build('t', { 'a #}' })), nil)
check('build rejects a bad name', (edit.build('1x', {})), nil)

-- set_key ---------------------------------------------------------------------
buf = buffer({ '  I. Head', '', '{# prop; effort: 2h; id: x #}' })
local tag = tag_at(buf, 3, 4)
check('set_key replace', edit.set_key(tag, 'effort', '3h'), true)
check('set_key replace text', lines(buf)[3], '{# prop; effort: 3h; id: x #}')
tag = tag_at(buf, 3, 4)
edit.set_key(tag, 'cat', 'work')
check('set_key add', lines(buf)[3], '{# prop; effort: 3h; id: x; cat: work #}')
tag = tag_at(buf, 3, 4)
edit.set_key(tag, 'effort', nil)
check('set_key remove', lines(buf)[3], '{# prop; id: x; cat: work #}')
tag = tag_at(buf, 3, 4)
check('set_key rejects an end', (edit.set_key(tag, 'id', 'a #}')), false)
check('set_key unchanged after a rejected value', lines(buf)[3], '{# prop; id: x; cat: work #}')

buf = buffer({ '  I. Head', '', '{# todo, TODO #}', '{# prop, a; #}' })
tag = tag_at(buf, 3, 4)
edit.set_key(tag, 'at', '2026-10-06')
check('set_key on a tag without keys', lines(buf)[3], '{# todo, TODO; at: 2026-10-06 #}')
tag = tag_at(buf, 4, 4)
edit.set_key(tag, 'k', 'v')
check('set_key after a trailing delimiter', lines(buf)[4], '{# prop, a; k: v #}')

-- multi line head keeps its layout
buf = buffer({ '  I. Head', '', '{# prop;', '     effort: 2h;', '     id: x', '#}', '' })
tag = tag_at(buf, 4, 8)
check('multi line tag found', tag and tag.name, 'prop')
edit.set_key(tag, 'effort', '5h')
check('multi line set_key', { lines(buf)[3], lines(buf)[4], lines(buf)[5], lines(buf)[6] }, { '{# prop;', '     effort: 5h;', '     id: x', '#}' })

-- values ----------------------------------------------------------------------
buf = buffer({ '  I. Head', '', '{# labels, a, b #}' })
tag = tag_at(buf, 3, 4)
edit.set_value(tag, 2, 'bee')
check('set_value replace', lines(buf)[3], '{# labels, a, bee #}')
tag = tag_at(buf, 3, 4)
edit.set_value(tag, 3, 'c')
check('set_value append', lines(buf)[3], '{# labels, a, bee, c #}')
tag = tag_at(buf, 3, 4)
edit.remove_value(tag, 1)
check('remove_value', lines(buf)[3], '{# labels, bee, c #}')
tag = tag_at(buf, 3, 4)
edit.rename(tag, 'label')
check('rename', lines(buf)[3], '{# label, bee, c #}')

-- remove ----------------------------------------------------------------------
buf = buffer({ '  I. Head', '', '{# prop; a: 1 #}', 'text {# x, 1 #} more', 'tail {# y, 2 #}', '' })
tag = tag_at(buf, 3, 4)
edit.remove(tag)
check('remove a tag alone on its line', lines(buf)[3], 'text {# x, 1 #} more')
tag = tag_at(buf, 3, 8)
edit.remove(tag)
check('remove an inline tag', lines(buf)[3], 'text more')
tag = tag_at(buf, 4, 8)
edit.remove(tag)
check('remove a trailing tag', lines(buf)[4], 'tail')

-- add_to_title / add_to_region ---------------------------------------------------
buf = buffer({ '  I. Write the report', '', 'Body.', '' })
root = vim.treesitter.get_parser(buf, 'fey'):parse()[1]:root()
edit.add_to_title(buf, root:field('subsection')[1], '{# todo, TODO #}', { first = true })
check('add_to_title first', lines(buf)[1], '  I. {# todo, TODO #} Write the report')
root = vim.treesitter.get_parser(buf, 'fey'):parse()[1]:root()
edit.add_to_title(buf, root:field('subsection')[1], '{# labels, a #}')
check('add_to_title end', lines(buf)[1], '  I. {# todo, TODO #} Write the report {# labels, a #}')
root = vim.treesitter.get_parser(buf, 'fey'):parse()[1]:root()
check('add_to_region new', edit.add_to_region(buf, root:field('subsection')[1], '{# scheduled, 2026-10-06 #}'), 1)
check('add_to_region new text', { lines(buf)[2], lines(buf)[3] }, { '{# scheduled, 2026-10-06 #}', '' })
root = vim.treesitter.get_parser(buf, 'fey'):parse()[1]:root()
edit.add_to_region(buf, root:field('subsection')[1], '{# deadline, 2026-10-07 #}')
check('add_to_region next', { lines(buf)[2], lines(buf)[3], lines(buf)[4] }, { '{# scheduled, 2026-10-06 #}', '{# deadline, 2026-10-07 #}', '' })
root = vim.treesitter.get_parser(buf, 'fey'):parse()[1]:root()
check('region after the edits', names((edit.for_heading(buf, root:field('subsection')[1]))), { 'todo', 'labels', 'scheduled', 'deadline' })

buf = buffer({ '  I.' })
root = vim.treesitter.get_parser(buf, 'fey'):parse()[1]:root()
-- a heading without a title gets its first title tag after the signature
if root:field('subsection')[1] then
  edit.add_to_title(buf, root:field('subsection')[1], '{# todo, TODO #}')
  check('add_to_title without a title', lines(buf)[1], '  I. {# todo, TODO #}')
end

-- the vault leaves metadata tags out of titles -----------------------------------
local extract = require('fey.vault.extract')
local meta = extract.extract('  I. {# status, TODO, A #} Write {# labels, a #} the report\n\n  I.A. Sub {# prop; x: 1 #}\n')
check('vault titles', vim.tbl_map(function(h) return h.title end, meta.headings), { 'Write the report', 'Sub' })
check('vault paths', meta.headings[2].path, 'Write the report/Sub')
check('vault keeps other tags in titles', extract.extract('  I. See {@ link, a.fey @} now\n').headings[1].title, 'See {@ link, a.fey @} now')
check('vault labels still found', vim.tbl_map(function(l) return l.label end, meta.labels), { 'a' })

if failures > 0 then
  print(('%d of %d checks failed'):format(failures, total))
  vim.cmd('cquit 1')
end
print(('ok: %d checks'):format(total))
vim.cmd('quit')
