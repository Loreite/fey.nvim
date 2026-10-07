-- Export: the model of a text, Markdown, HTML, iCalendar, files. Run from the repo root:
--
--   FEY_PARSER=/path/to/fey.so nvim --headless --clean -l tests/export.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
if vim.env.FEY_PARSER then vim.treesitter.language.add('fey', { path = vim.env.FEY_PARSER }) end
vim.cmd('filetype plugin indent on')

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
  vim.fn.mkdir(d .. '/.fey', 'p')
  return d
end)())
require('fey').setup({ fey_court_dir = base .. '/court' })
local Export = require('fey.export')
local inline = require('fey.export.inline')

local function md(lines) return Export.markdown(table.concat(lines, '\n') .. '\n') end
local function has(s, needle) return s ~= nil and s:find(needle, 1, true) ~= nil end

-- emphasis --------------------------------------------------------------------------------------------------
local function flat(items)
  return vim.tbl_map(function(i) return i.t == 'em' and (i.kind .. ':' .. flat(i.children)[1]) or (i.s or i.t) end, items)
end
check('bold and italic', flat(inline.parse('a !b! and /c/ d')), { 'a ', 'bold:b', ' and ', 'italic:c', ' d' })
check('code', flat(inline.parse('see `x!y!` here')), { 'see ', 'x!y!', ' here' })
check('a path is not emphasis', flat(inline.parse('in a/b/c now')), { 'in a/b/c now' })
check('snake case is not emphasis', flat(inline.parse('a snake_case_name')), { 'a snake_case_name' })
check('a lone marker is text', flat(inline.parse('well! it works')), { 'well! it works' })
check('escaped', flat(inline.parse('\\!not bold!')), { '!not bold!' })
local nested = inline.parse('!a /b/ c!')
check('nested', { nested[1].kind, nested[1].children[2].kind }, { 'bold', 'italic' })

-- structure -------------------------------------------------------------------------------------------------
local doc = md({
  '{# table; title: My Doc; author: Me #}',
  '',
  '  I. {# status, TODO #} Intro {# labels, a, b #}',
  '{# prop; id: x #}',
  '{# deadline, 2026-10-07 Wed #}',
  '',
  'Some !bold! and /italic/ text',
  '',
  '-  one',
  '-  [x] two',
  '   -  nested',
  '',
  '| h1 | h2 |',
  '+====+====+',
  '| a  | b  |',
  '',
  '###  src lua :tangle out.lua',
  'print(1)',
  '###',
  '',
  '  I.A. Child',
  '',
  'child text',
})
check('front matter', has(doc, '---\ntitle: "My Doc"\nauthor: "Me"\n---'), true)
check('a heading with its keyword', has(doc, '# TODO Intro'), true)
check('labels', has(doc, '`a` `b`'), true)
check('a child heading is one level down', has(doc, '\n## Child\n'), true)
check('emphasis', has(doc, 'Some **bold** and *italic* text'), true)
check('a list with a checkbox and a nested item', has(doc, '- one\n- [x] two\n  - nested'), true)
check('a table', has(doc, '| h1 | h2 |\n| --- | --- |\n| a | b |'), true)
check('a source block keeps its language and loses its arguments', has(doc, '```lua\nprint(1)\n```'), true)
check('the machinery is not in it', { has(doc, 'deadline'), has(doc, 'prop'), has(doc, 'status'), has(doc, 'x') }, { false, false, false, true })
check('a heading does not become two', select(2, doc:gsub('\n# ', '\n# ')), 1)

-- links, footnotes, math -------------------------------------------------------------------------------------
doc = md({
  '  I. Links',
  '',
  'to {@ link, notes/a.fey; desc: The notes @} and {@ link, b.fey; section: II. @} and {@ link, https://example.com @}',
  'and {@ section, II.A. @} and {@ link, id:xyz @} with a note {@ fn, one @}',
  '',
  '[ fn, one #]',
  'The note.',
  '[# fn ]',
  '',
  '#[ math ] E = mc^2 #',
  '',
  '[ math ]#',
  '   \\int_0^1 x \\, dx',
  '',
  '  II. Other',
})
check('a link to a note is a link to the exported file', has(doc, '[The notes](notes/a.md)'), true)
check('with no description it is the name, with a section an anchor', has(doc, '[b](b.md#sec-II)'), true)
check('a url', has(doc, '[https://example.com](https://example.com)') or has(doc, '(https://example.com)'), true)
check('a section tag is an anchor', has(doc, '#sec-II-A'), true)
check('an id link has nowhere to go in a file: its text only', { has(doc, '](id:'), has(doc, 'xyz') }, { false, true })
check('a footnote', { has(doc, 'note [^one]'), has(doc, '[^one]: The note.') }, { true, true })
check('inline math', has(doc, '$E = mc^2$'), true)
check('display math', has(doc, '$$\n\\int_0^1 x \\, dx\n$$'), true)

-- comments: every form ---------------------------------------------------------------------------------------
doc = md({
  '  I. Comments',
  '',
  'kept one',
  '',
  '#[ comment ] line comment #',
  '',
  '[ comment ]#',
  '   block comment',
  '',
  '[ comment #]',
  'pair comment',
  '[# comment ]',
  '',
  'a paragraph {# comment #} hidden by a scope tag',
  '',
  '-  one',
  '-  {# comment #}',
  '-  three',
  '',
  'kept two',
})
check('comments are hidden in every form', { has(doc, 'line comment'), has(doc, 'block comment'), has(doc, 'pair comment'), has(doc, 'hidden by a scope'), has(doc, 'three') }, { false, false, false, false, false })
check('the rest stays', { has(doc, 'kept one'), has(doc, 'kept two') }, { true, true })
check('a file that is all commented has nothing to export', md({ '{# comment #}', '', 'text', '', '  I. H', '', 'more' }), nil)
check('a scope comment in a section hides the text of the section, not the subsections', has(md({ '  I. A', '', '{# comment #}', '', 'hidden', '', '  I.A. B', '', 'shown' }), 'shown'), true)

-- a link around blocks ------------------------------------------------------------------------------------------
doc = md({ '  I. L', '', '[ link, target.fey ]#', '   a paragraph that is the link', '', '   another one', '' })
check('a block link wraps what it holds', { has(doc, '[a paragraph that is the link](target.md)'), has(doc, '[another one](target.md)') }, { true, true })

-- results of queries are content ---------------------------------------------------------------------------------
doc = md({ '  I. Q', '', '{# query, LIST #}', '', '[ query_result #]', '-  {@ link, a.fey @}', '[# query_result ]' })
check('the query tag is not shown, its result is', { has(doc, 'LIST'), has(doc, '[a](a.md)') }, { false, true })

-- html -------------------------------------------------------------------------------------------------------------
local html = Export.html(table.concat({ '  I. A & B', '', 'x < y {@ link, b.fey @}', '', '-  [ ] open', '', '  I.A. Sub', '', '  I.A. Sub', '' }, '\n') .. '\n')
check('html is a page', has(html, '<!doctype html>') and has(html, '</html>'), true)
check('escaped text', has(html, 'A &amp; B') and has(html, 'x &lt; y'), true)
check('links go to html', has(html, '<a href="b.html">b</a>'), true)
check('headings have ids', has(html, '<section id="sec-I">') and has(html, '<section id="sec-I-A">'), true)
check('ids are unique', has(html, '<section id="sec-I-A-2">'), true)
check('a checkbox', has(html, '<input type="checkbox" disabled>'), true)


-- merged cells: embedded HTML in Markdown, the table itself in HTML ------------------------------------------------
local MERGED = {
  '  I. T',
  '',
  '| h1 | h2 | h3 |',
  '+====+====+====+',
  'v----*----v----v',
  '| a       | c  |',
  '| b       |    |',
  '+~~~~+~~~~+    +',
  '| d  | e  |    |',
  '^----^----^----^',
  '',
  '| x | y |',
}
doc = md(MERGED)
check('merged cells in Markdown are an HTML table', has(doc, '<table>') and has(doc, '<th>h1</th>'), true)
check('with their spans', has(doc, '<td colspan="2">a b</td>') and has(doc, '<td rowspan="2">c</td>'), true)
check('the cells a span covers are not written again', select(2, doc:gsub('<td>', '')) , 2)
check('a table with no merged cell stays a Markdown table', has(doc, '| x | y |'), true)
local merged_html = Export.html(table.concat(MERGED, '\n') .. '\n')
check('merged cells in HTML', has(merged_html, '<td colspan="2">a b</td>') and has(merged_html, '<td rowspan="2">c</td>') and has(merged_html, '<thead>'), true)
check('cells hold inline markup', has(md({ '  I. T', '', '| h1 | h2 | h3 |', '+====+====+====+', 'v----*----v----v', '| !a!      | b  |', '^----^----^----^' }), '<strong>a</strong>'), true)

-- tags named like HTML elements -----------------------------------------------------------------------------------------
doc = md({
  '  I. H',
  '',
  'a #[ mark; class: hot ] marked words # here and #[ kbd ] Ctrl # and {# span #}',
  '',
  '[ div; class: note; id: n1 ]#',
  '   inside the div !bold!',
  '',
  '[ details #]',
  '[ summary ]#',
  '   Sum',
  'more',
  '[# details ]',
  '',
  '#[ span; onclick: evil(); href: javascript:evil() ] safe # and {@ section, I. @}',
})
check('an inline element', has(doc, '<mark class="hot">marked words</mark>') and has(doc, '<kbd>Ctrl</kbd>'), true)
check('a block element with attributes, its content is Markdown', has(doc, '<div class="note" id="n1">\n\ninside the div **bold**\n\n</div>'), true)
check('details and summary', has(doc, '<details>') and has(doc, '<summary>') and has(doc, '</details>'), true)
check('event attributes are not written', has(doc, 'onclick'), false)
check('a tag of the notes keeps its meaning', has(doc, '<section'), false)
local el = Export.html(table.concat({ '  I. H', '', '#[ mark; class: hot ] words # and', '', '[ div; class: note ]#', '   inside', '' }, '\n') .. '\n')
check('the element itself in HTML', has(el, '<mark class="hot">words</mark>') and has(el, '<div class="note">') and has(el, '</div>'), true)


-- names that conflict: the weaker one ends with an underscore -------------------------------------------------------------
doc = md({ '  I. H', '', '[ section_; class: s ]#', '   in a section element', '', '[ table_ ]#', '   in a table element', '', '{@ section, I. @}' })
check('section_ is the HTML section', has(doc, '<section class="s">') and has(doc, 'in a section element') and has(doc, '</section>'), true)
check('and section is still the link', has(doc, '#sec-I'), true)
check('table_ is the HTML table element', has(doc, '<table>') and has(doc, '</table>'), true)
check('section without an underscore is not an element', has(md({ '  I. H', '', '[ section ]#', '   text', '' }), '<section'), false)
check('an unknown name with an underscore is not an element', has(md({ '  I. H', '', '[ nothing_ ]#', '   text', '' }), '<nothing'), false)

-- a tag of your own with an export of its own -------------------------------------------------------------------------------
local config = require('fey.config')
config:extend({
  tag_exports = {
    note = {
      block_tag = [[<aside class="note">\n%s\n</aside>]],
      pair_tag = [[<aside class="pair">\n%s\n</aside>]],
      line_tag = [[<span class="note">%s</span>]],
      scope_tag = [[<div class="scoped">\n%s\n</div>]],
    },
    div = [[<div class="mine">%s</div>]],
    shout = function(body, tag, target) return ('<b data-target="%s" data-form="%s">%s</b>'):format(target, tag.form, body) end,
    split = { html = { default = [[<i>%s</i>]] }, markdown = { default = [[_%s_]] } },
    percent = [[100%% of %s]],
  },
})
doc = md({
  '  I. H',
  '',
  '[ note ]#',
  '   in a block !bold!',
  '',
  '[ note #]',
  'in a pair',
  '[# note ]',
  '',
  'a line #[ note ] tag text # in a paragraph',
  '',
  'scoped text {# note #} here',
  '',
  '#[ shout ] loud #',
  '',
  '#[ split ] twice #',
  '',
  '#[ percent ] it #',
})
check('a block form', has(doc, '<aside class="note">\n\nin a block **bold**\n\n</aside>'), true)
check('a pair form', has(doc, '<aside class="pair">\n\nin a pair\n\n</aside>'), true)
check('a line form', has(doc, 'a line <span class="note">tag text</span> in a paragraph'), true)
check('a scope form wraps what the tag applies to', has(doc, '<div class="scoped">\n\nscoped text  here\n\n</div>'), true)
check('a function gets the body, the tag and the target', has(doc, '<b data-target="markdown" data-form="line_tag">loud</b>'), true)
check('Markdown has its own forms', has(doc, '_twice_'), true)
check('a percent sign', has(doc, '100% of it'), true)
local html_doc = Export.html(table.concat({ '  I. H', '', '[ note ]#', '   in a block', '', '#[ split ] twice #', '', '#[ shout ] loud #' }, '\n') .. '\n')
check('the same forms in HTML', has(html_doc, '<aside class="note">') and has(html_doc, '<i>twice</i>') and has(html_doc, 'data-target="html"'), true)

-- a scope tag applies to its implied body
doc = md({ '  I. H', '', '-  one', '-  {# note #}', '-  three', '', 'after' })
check('alone in a list item: the whole list', has(doc, '<div class="scoped">') and has(doc, '- one') and has(doc, '- three'), true)
check('and not what is after the list', doc:find('after', 1, true) > doc:find('</div>', 1, true), true)
doc = md({ '  I. H', '', '-  one {# note #}', '   -  nested', '-  two' })
check('in an item with other contents: the paragraph only', has(doc, '<div class="scoped">\n\none \n\n</div>') or has(doc, '<div class="scoped">'), true)
doc = md({ '{# note #}', '', 'first text', '', '  I. H', '', 'second' })
check('above the first heading: the whole file', doc:find('<div class="scoped">', 1, true) < doc:find('first text', 1, true) and doc:find('</div>', 1, true) > doc:find('second', 1, true), true)
doc = md({ '  I. H', '', '{# note #}', '', 'text of the section', '', '  I.A. Sub', '', 'sub text' })
check('in a section: the text of the section, not the subsections', doc:find('</div>', 1, true) < doc:find('Sub', 1, true), true)

-- the name is taken: the element is `div_`
doc = md({ '  I. H', '', '[ div ]#', '   mine', '', '[ div_; class: real ]#', '   html', '' })
check('a tag of your own named div keeps its meaning', has(doc, '<div class="mine">'), true)
check('div_ is the HTML div', has(doc, '<div class="real">'), true)
-- an editor handler takes the name too
require('fey.files.elements.tags').handlers.kbd = { scope_tag = function() end }
doc = md({ '  I. H', '', '#[ kbd ] Ctrl #', '', '#[ kbd_ ] Alt #' })
check('a name with a handler is not the element', { has(doc, '<kbd>Ctrl'), has(doc, '<kbd>Alt</kbd>') }, { false, true })
require('fey.files.elements.tags').handlers.kbd = nil
-- added at run time
Export.tag('runtime', { line_tag = [[<u>%s</u>]] })
check('Export.tag adds an export', has(md({ '  I. H', '', '#[ runtime ] now #' }), '<u>now</u>'), true)
for name in pairs(config.tag_exports) do
  config.tag_exports[name] = nil
end
check('without the export the tag keeps what it holds', has(md({ '  I. H', '', '#[ note ] plain #' }), '<span class="note">'), false)

-- icalendar ---------------------------------------------------------------------------------------------------------
local ts = os.time({ year = 2026, month = 10, day = 7, hour = 9, min = 30 })
local ics = require('fey.export.ics').render({
  { path = 'a.fey', line = 2, kind = 'deadline', active = 1, start_ts = ts, start_time = 1, heading_title = 'Report, final' },
  { path = 'a.fey', line = 5, kind = 'scheduled', active = 1, start_ts = os.time({ year = 2026, month = 10, day = 8, hour = 0 }), start_time = 0, heading_title = 'Plan' },
  { path = 'a.fey', line = 8, kind = 'closed', active = 0, start_ts = ts, start_time = 1, heading_title = 'Done' },
}, { now = ts, name = 'a' })
check('ics frame', { ics:sub(1, 15), has(ics, 'END:VCALENDAR') }, { 'BEGIN:VCALENDAR', true })
check('two events, not the closed one', select(2, ics:gsub('BEGIN:VEVENT', '')), 2)
check('a timed deadline', has(ics, 'DTSTART:20261007T093000') and has(ics, 'SUMMARY:Deadline: Report\\, final'), true)
check('an all day event ends the day after', has(ics, 'DTSTART;VALUE=DATE:20261008') and has(ics, 'DTEND;VALUE=DATE:20261009'), true)
check('lines end with CRLF', has(ics, 'VERSION:2.0\r\n'), true)
check('long lines are folded', #require('fey.export.ics').render({ { path = 'a', line = 1, kind = 'date', active = 1, start_ts = ts, start_time = 0, heading_title = ('x'):rep(200) } }):match('SUMMARY:[^\r]*'), 75)

-- files -------------------------------------------------------------------------------------------------------------
local shown
Export.done = function(target) shown = target end
vim.fn.writefile({ '{# table; title: T #}', '{# labels, topic #}', '', '  I. File', '', 'text {@ link, other.fey @}', '', '  II. Dated {# status, TODO #}', '{# deadline, 2026-10-09 Fri #}' }, base .. '/doc.fey')
vim.fn.writefile({ '{# labels, topic #}', '', '  I. Other', '', 'more' }, base .. '/other.fey')
local vault = require('fey.vault').open(base)
local done = false
vault:scan({}, function() done = true end)
vim.wait(5000, function() return done end, 10)
vim.cmd('edit ' .. vim.fn.fnameescape(base .. '/doc.fey'))
vim.bo.filetype = 'fey'
check('markdown file', { Export.file('markdown') == base .. '/doc.md', shown == base .. '/doc.md' }, { true, true })
check('its text', has(table.concat(vim.fn.readfile(base .. '/doc.md'), '\n'), '# File'), true)
Export.file('html')
check('html file', has(table.concat(vim.fn.readfile(base .. '/doc.html'), '\n'), '<a href="other.html">other</a>'), true)
Export.file('ics')
local ics_file = table.concat(vim.fn.readfile(base .. '/doc.ics'), '\n')
check('ics file from the index', has(ics_file, 'DTSTART;VALUE=DATE:20261009') and has(ics_file, 'Deadline: Dated'), true)
local targets = Export.label('topic', 'markdown', base)
table.sort(targets)
check('a label exports its files', vim.tbl_map(function(t) return vim.fn.fnamemodify(t, ':t') end, targets), { 'doc.md', 'other.md' })

-- pandoc reads the Markdown (when it is installed)
if vim.fn.executable('pandoc') == 1 then
  local target = Export.file('latex')
  vim.wait(15000, function() return vim.uv.fs_stat(target) ~= nil and shown == target end, 50)
  local tex = vim.uv.fs_stat(target) and table.concat(vim.fn.readfile(target), '\n') or ''
  check('latex through pandoc', { has(tex, '\\section{File}'), has(tex, 'text') }, { true, true })
  target = Export.file('odt')
  vim.wait(15000, function() return vim.uv.fs_stat(target) ~= nil and shown == target end, 50)
  check('odt through pandoc', vim.uv.fs_stat(target) ~= nil and vim.uv.fs_stat(target).size > 1000, true)
  target = Export.file('docx')
  vim.wait(15000, function() return vim.uv.fs_stat(target) ~= nil and shown == target end, 50)
  check('docx through pandoc', vim.uv.fs_stat(target) ~= nil and vim.uv.fs_stat(target).size > 1000, true)
end
check('an unknown format', Export.file('nonsense'), nil)
check('the old emacs path is gone', { Export.emacs, Export.pandoc }, {})

vault:close()
print(('export: %d checks, %d failures'):format(total, failures))
vim.cmd(failures == 0 and 'qa!' or 'cq!')
