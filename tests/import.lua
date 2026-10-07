-- Importing Markdown (Obsidian's included) and org, in place, on files and from the command line. Run from the repo root:
--
--   FEY_PARSER=/path/to/fey.so nvim --headless --clean -l tests/import.lua
vim.opt.rtp:prepend('.')
if vim.env.FEY_PARSER then vim.treesitter.language.add('fey', { path = vim.env.FEY_PARSER }) end
require('fey').setup({ fey_court_dir = vim.fn.tempname() .. '/court' })
local Import = require('fey.import')

local failures, total = 0, 0
local function check(name, got, want)
  total = total + 1
  if not vim.deep_equal(got, want) then
    failures = failures + 1
    print(('FAIL %s\n  got:  %s\n  want: %s'):format(name, vim.inspect(got), vim.inspect(want)))
  end
end
local function has(name, text, needle)
  total = total + 1
  if not (text and text:find(needle, 1, true)) then
    failures = failures + 1
    print(('FAIL %s\n  missing: %s\n  in:\n%s'):format(name, needle, tostring(text)))
  end
end
local function lacks(name, text, needle)
  total = total + 1
  if text and text:find(needle, 1, true) then
    failures = failures + 1
    print(('FAIL %s\n  should not have: %s\n  in:\n%s'):format(name, needle, tostring(text)))
  end
end
local function parses(name, text)
  total = total + 1
  local root = vim.treesitter.get_string_parser(text, 'fey'):parse()[1]:root()
  if root:has_error() then
    failures = failures + 1
    print(('FAIL %s: the result does not parse\n%s'):format(name, text))
  end
end

-- Markdown ----------------------------------------------------------------------------------------------------------------

local md = table.concat({
  '---',
  'title: Garden',
  'tags: [plants, "to-do"]',
  'aliases:',
  '  - yard',
  '  - plot',
  '---',
  '# Vegetables *and* fruit',
  '',
  'Some **bold**, *italic*, ~~gone~~, `code`, a [link](notes/other.md#top) and [[Other Note|the note]], [[Plain]] and ![[pic.png]].',
  'A #tag in text, inline math $x^2$ and a footnote[^1].',
  '',
  '- [ ] open',
  '- [x] done',
  '- [/] under way',
  '  - child item',
  '',
  '1. first',
  '2. second',
  '',
  '> [!warning] Careful',
  '> hot soil',
  '',
  '| Name | Count |',
  '|------|:-----:|',
  '| kale | 3 |',
  '| a \\| b | 4 |',
  '',
  '```lua',
  'print(1)',
  '```',
  '',
  '$$',
  'a = b',
  '$$',
  '',
  '%% hidden note %%',
  '',
  '## Roots',
  '',
  'Deeper.',
  '',
  'Setext heading',
  '--------------',
  '',
  '#### Skipped levels',
  '',
  '[^1]: The note.',
  '',
}, '\n')

local text, warnings = Import.text(md, 'markdown')
check('markdown: no warnings', warnings, {})
parses('markdown: parses', text)
has('md: data tag', text, '{# table; title: Garden; aliases: yard\\, plot #}')
has('md: front matter labels', text, '{# labels, plants, to-do #}')
has('md: first heading', text, '  I. Vegetables /and/ fruit')
has('md: second level', text, '  I.A. Roots')
has('md: setext heading is a heading too', text, '  I.B. Setext heading')
has('md: skipped levels nest', text, '  I.B.i. Skipped levels')
has('md: bold italic strike code', text, '!bold!, /italic/, ~gone~, `code`')
has('md: relative link to a note', text, '{@ link, notes/other.fey#top; desc: link @}')
has('md: wikilink with alias', text, '{@ link, Other Note.fey; desc: the note @}')
has('md: plain wikilink', text, '{@ link, Plain.fey; desc: Plain @}')
has('md: embed', text, '{@ link, pic.png; embed: true @}')
has('md: tag in text', text, '{# labels, tag #}')
has('md: inline math', text, '#[ math ] x^2 #')
has('md: footnote reference', text, '{@ fn, 1 @}')
has('md: footnote definition', text, '#[ fn, 1 ] The note. #')
has('md: open box', text, '-  [ ] open')
has('md: done box', text, '-  [x] done')
has('md: Obsidian mark', text, '-  [/] under way')
has('md: nested item', text, '   -  child item')
has('md: ordered list', text, '1.  first\n2.  second')
has('md: callout', text, '[ blockquote; class: callout callout-warning ]#\n   !Careful!\n\n   hot soil')
has('md: table', text, '| Name   | Count |\n+========+=======+\n| kale   | 3     |')
has('md: table cell with a bar', text, '| a \\| b | 4     |')
has('md: fenced code', text, '###  src lua\nprint(1)\n###')
has('md: display math', text, '[ math ]#\n   a = b')
has('md: Obsidian comment', text, '#[ comment ] hidden note #')

-- what the exporter makes of it comes back
local back = require('fey.export').markdown(text)
has('md round trip: heading', back, '# Vegetables *and* fruit')
has('md round trip: task', back, '- [x] done')
has('md round trip: wikilink', back, '[the note](Other%20Note.md)')
has('md round trip: code', back, '```lua\nprint(1)\n```')

-- other front matter, no link rewriting
local t2 =
  Import.text('---\ntitle: "Quoted: yes"\ntags: one, two\n---\nSee [x](a.md).\n', 'markdown', { link_extension = false })
has('md: quoted title', t2, 'title: Quoted: yes')
has('md: labels from a plain list', t2, '{# labels, one, two #}')
has('md: link kept', t2, '{@ link, a.md; desc: x @}')
parses('md: second parses', t2)

-- Tasks emoji dates, a link reference, html
local t3, w3 = Import.text(
  '- [ ] pay 📅 2026-10-10\n\nSee [ref] and <b>bold</b>.\n\n[ref]: http://r.example\n\n<!-- aside -->\n',
  'markdown'
)
has('md: task date', t3, '{@ date, 2026-10-10 @}')
has('md: reference link', t3, '{@ link, http://r.example; desc: ref @}')
has('md: html comment', t3, '#[ comment ] aside #')
check('md: inline html warns', w3, { 'inline HTML tags were dropped' })

-- what a tag head can hold: a closing bracket at the start of a word is fine in the scope tag of a link, a sign and a closing bracket (`->`) is not
local t4, w4 = Import.text('A [a > b](x.md) and [go -> there](y.md) and [c ) d](z.md).\n', 'markdown')
has('md: a closing bracket in a description', t4, '{@ link, x.fey; desc: a > b @}')
has('md: ... and a bracket alone', t4, '{@ link, z.fey; desc: c ) d @}')
has('md: a description with a word like -> is fine', t4, '{@ link, y.fey; desc: go -> there @}')
check('md: ... and needs no note', #w4, 0)
do
  local root = vim.treesitter.get_string_parser(t4, 'fey'):parse()[1]:root()
  local n = 0
  local function count(node)
    if node:type() == 'scope_tag' then n = n + 1 end
    for c in node:iter_children() do
      count(c)
    end
  end
  count(root)
  check('md: the links are tags for the grammar, not text', n, 3)
end
-- a bar in a paragraph of a block that is a pair tag in the source, and a fence on the line of a bullet
local t5 = Import.text('> quoted | with a bar\n\n- ```lua\n  x\n  ```\n- next\n\n```sh\nls\n```\n', 'markdown')
parses('md: a bar in a quote', t5)
has('md: a fence in a list item', t5, '-  ###  src lua\n   x\n   ###')
do
  local root = vim.treesitter.get_string_parser(t5, 'fey'):parse()[1]:root()
  local blocks = 0
  local function count(node)
    if node:type() == 'block' then blocks = blocks + 1 end
    for c in node:iter_children() do
      count(c)
    end
  end
  count(root)
  check('md: both fences are blocks', blocks, 2)
end

-- org ---------------------------------------------------------------------------------------------------------------------

local org_ok = require('fey.import.org').available()
if org_ok then
  local org = table.concat({
    '#+title: Test',
    '#+filetags: :a:b:',
    '#+todo: TODO NEXT | DONE',
    '',
    'Intro with *bold* and /it/ and =verb= and [[https://x.y][link]] and [[file:b.org::*Head]].',
    '',
    '* TODO [#A] Head one :work:home:',
    'SCHEDULED: <2026-10-07 Wed 10:00> DEADLINE: <2026-10-10 Sat>',
    ':PROPERTIES:',
    ':ID: abc',
    ':EFFORT: 2h',
    ':END:',
    ':LOGBOOK:',
    'CLOCK: [2026-10-06 Tue 10:00]--[2026-10-06 Tue 11:30] =>  1:30',
    ':END:',
    'Text under. A footnote[fn:1] and <2026-10-07 Wed +1w>.',
    '',
    '- item one',
    '  - [ ] sub task [1/2]',
    '  - [-] part',
    '  - [X] sub done',
    '1. first',
    '',
    '** DONE Child',
    'CLOSED: [2026-10-07 Wed 09:00]',
    '#+name: demo',
    '#+begin_src python :tangle x.py',
    'print(1)',
    '#+end_src',
    '',
    '#+begin_quote',
    'Quoted',
    '#+end_quote',
    '',
    '| a | b |',
    '|---+---|',
    '| 1 | 2 |',
    '#+tblfm: $3=$1+$2::@2$1=5',
    '',
    '# a comment',
    '[fn:1] The note.',
    '',
    '* Second :ARCHIVE:',
    ':MYDRAWER:',
    'inside',
    ':END:',
  }, '\n')
  local otext, ow = Import.text(org, 'org')
  check('org: no warnings', ow, {})
  parses('org: parses', otext)
  has('org: data', otext, '{# table; title: Test; todo: TODO NEXT | DONE #}')
  has('org: filetags', otext, '{# labels, a, b #}')
  has('org: markup', otext, '!bold! and /it/ and `verb`')
  has('org: link with a description', otext, '{@ link, https://x.y; desc: link @}')
  has('org: file link to a fey file', otext, '{@ link, b.fey @}')
  has('org: heading with status and labels', otext, '  I. {# status, TODO, A #} Head one {# labels, work, home #}')
  has('org: planning', otext, '{# scheduled, 2026-10-07 Wed 10:00 #} {# deadline, 2026-10-10 Sat #}')
  has('org: properties', otext, '{# prop; id: abc; effort: 2h #}')
  has('org: clock', otext, '{# clock, 2026-10-06 Tue 10:00; end: 2026-10-06 Tue 11:30; dur: 1:30 #}')
  has('org: logbook', otext, '[ logbook #]')
  has('org: footnote', otext, 'A footnote{@ fn, 1 @}')
  has('org: inline date with a repeater', otext, '{@ date, 2026-10-07 Wed +1w @}')
  has('org: footnote definition', otext, '#[ fn, 1 ] The note. #')
  has('org: boxes', otext, '   -  [ ] sub task [1/2]\n   -  [/] part\n   -  [x] sub done')
  has('org: child heading', otext, '  I.A. {# status, DONE #} Child')
  has('org: closed', otext, '{# closed, 2026-10-07 Wed 09:00 #}')
  has('org: source block with arguments and a name', otext, '###  src python :tangle x.py :name demo\nprint(1)\n###')
  has('org: quote', otext, '[ blockquote ]#\n   Quoted')
  has('org: table header', otext, '| a | b |\n+===+===+\n| 1 | 2 |')
  has('org: table formula', otext, '| 1 | 2 |\n#[ tblfm ] $3=$1+$2::@2$1=5 #')
  has('org: comment', otext, '#[ comment ] a comment #')
  has('org: archive tag is the label', otext, '  II. Second {# labels, archive #}')
  has('org: other drawer is a block tag', otext, '[ mydrawer ]#\n   inside')

  -- the clock round trips into the index of a vault
  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. '/.fey', 'p')
  local extract = require('fey.vault.extract').extract(otext, {})
  check('org: the index finds the task', extract.tasks and extract.tasks[1] and extract.tasks[1].state, 'TODO')
else
  print('skip org: the tree-sitter parser for org is not installed')
end

-- a buffer, in place -------------------------------------------------------------------------------------------------------

local buf = vim.api.nvim_create_buf(true, false)
local undolevels = vim.bo[buf].undolevels
vim.bo[buf].undolevels = -1
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '# Title', '', 'Some **bold** text.' })
vim.bo[buf].undolevels = undolevels
vim.bo[buf].filetype = 'markdown'
vim.api.nvim_set_current_buf(buf)
local ok = Import.buffer(buf)
check('buffer: ok', ok, true)
check('buffer: lines', vim.api.nvim_buf_get_lines(buf, 0, -1, false), { '  I. Title', '', 'Some !bold! text.' })
check('buffer: filetype', vim.bo[buf].filetype, 'fey')
vim.cmd('undo')
check('buffer: one undo step', vim.api.nvim_buf_get_lines(buf, 0, -1, false), { '# Title', '', 'Some **bold** text.' })
local bad, why = Import.buffer(buf, 'rst')
check('buffer: unknown format', { bad, type(why) }, { false, 'string' })

-- files -------------------------------------------------------------------------------------------------------------------

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, 'p')
local function put(name, content)
  local fh = io.open(dir .. '/' .. name, 'wb')
  fh:write(content)
  fh:close()
  return dir .. '/' .. name
end
local function get(name)
  local fh = io.open(dir .. '/' .. name, 'rb')
  if not fh then return nil end
  local s = fh:read('*a')
  fh:close()
  return s
end

local a = put('a.md', '# One\n\ntext\n')
local r = Import.file(a)
check('file adjacent: target', r.target, dir .. '/a.fey')
check('file adjacent: new file', get('a.fey'), '  I. One\n\ntext\n')
check('file adjacent: source kept', get('a.md'), '# One\n\ntext\n')
local again = Import.file(a)
has('file adjacent: refuses to overwrite', again.err, 'the file exists')
check('file adjacent: force', Import.file(a, { force = true }).err, nil)
local dry = Import.file(put('d.md', '# D\n'), { dry_run = true })
check('file dry run: nothing written', { dry.err, get('d.fey') }, { nil, nil })

put('b.md', '# Two\n')
local rr = Import.file(dir .. '/b.md', { write = 'replace' })
check('file replace: same path', rr.target, dir .. '/b.md')
check('file replace: content', get('b.md'), '  I. Two\n')

put('c.md', '# Three\n')
Import.file(dir .. '/c.md', { write = 'rename' })
check('file rename: new name', get('c.fey'), '  I. Three\n')
check('file rename: old file gone', get('c.md'), nil)

check('file: unknown extension', Import.file(put('x.txt', 'hi')).err ~= nil, true)
check('file: missing', Import.file(dir .. '/none.md').err ~= nil, true)
check('file: forced format', Import.file(put('y.txt', '# Y\n'), { format = 'markdown' }).err, nil)
local batch = Import.files({ put('p.md', '# P\n'), dir .. '/none.md', put('q.md', '# Q\n') })
check(
  'batch: one failing does not stop the rest',
  { batch[1].err, batch[2].err ~= nil, batch[3].err, get('q.fey') },
  { nil, true, nil, '  I. Q\n' }
)

-- the command line --------------------------------------------------------------------------------------------------------

local function cli(...)
  local res = vim
    .system({ './bin/fey', ... }, { text = true, env = { NVIM_BIN = vim.v.progpath, FEY_PARSER = vim.env.FEY_PARSER } })
    :wait()
  return res.code, res.stdout, res.stderr
end
local code, out = cli('import', put('cli.md', '# Cli\n\nbody\n'))
check('cli import: exit', code, 0)
has('cli import: reports', out, 'cli.md -> ')
check('cli import: file', get('cli.fey'), '  I. Cli\n\nbody\n')
local code2, _, err2 = cli('import', dir .. '/cli.md')
check('cli import: refuses to overwrite', code2, 1)
has('cli import: says why', err2, 'the file exists')
local code3 = cli('export', '--format', 'markdown', dir .. '/cli.fey')
check('cli export: refuses to overwrite the source note it would clobber', code3, 1)
local code4, out4 = cli('export', '--format', 'html', '--outdir', dir .. '/out', dir .. '/cli.fey')
check('cli export: exit', code4, 0)
has('cli export: reports', out4, 'cli.html')
has('cli export: html', get('out/cli.html'), '<h1')
check('cli export: the Fey file is kept', get('cli.fey'), '  I. Cli\n\nbody\n')
local code5, _, err5 = cli('export', dir .. '/cli.fey')
check('cli export: needs a format', code5, 1)
has('cli export: says so', err5, '--format')
local code6, out6 = cli('help')
check('cli help', { code6, out6:find('usage: fey import', 1, true) ~= nil }, { 0, true })

print(('import: %d checks, %d failures'):format(total, failures))
vim.cmd(failures == 0 and 'qa!' or 'cquit 1')
