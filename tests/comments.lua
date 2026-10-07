-- The comment tag in every form, and what the index skips. Run from the repo root:
--
--   FEY_PARSER=/path/to/fey.so nvim --headless --clean -l tests/comments.lua
vim.opt.rtp:prepend('.')
if vim.env.FEY_PARSER then vim.treesitter.language.add('fey', { path = vim.env.FEY_PARSER }) end
local config = require('fey.config')
config:extend({})
config:setup_ts_predicates()
local Tag = require('fey.files.elements.tags')
Tag.setup({})
local comment = require('fey.files.elements.tags.handlers.comment')
local extract = require('fey.vault.extract')

local failures, total = 0, 0
local function check(name, got, want)
  total = total + 1
  if not vim.deep_equal(got, want) then
    failures = failures + 1
    print(('FAIL %s\n  got:  %s\n  want: %s'):format(name, vim.inspect(got), vim.inspect(want)))
  end
end

local query = vim.treesitter.query.get('fey', 'fey_tags')
local function root_of(text)
  local parser = vim.treesitter.get_string_parser(text, 'fey')
  return parser:parse()[1]:root()
end
---The text each comment tag comments, in the order of the tags
local function commented(text)
  local root = root_of(text)
  local out = {}
  for _, b in ipairs(comment.bodies(root, text, query)) do
    out[#out + 1] = vim.trim(text:sub(b.from + 1, b.to))
  end
  return out
end

-- the forms ---------------------------------------------------------------------------
check('line tag', commented('  I. H\n\n#[ comment ] hidden words #\n'), { 'hidden words' })
check('block tag', commented('  I. H\n\n[ comment ]#\n   one\n   two\n\nafter\n'), { 'one\n   two' })
check('pair tag', commented('  I. H\n\n[ comment #]\nsecret\n[# comment ]\n\nafter\n'), { 'secret' })
check('scope tag comments its paragraph', commented('  I. H\n\nbefore {# comment #} after\n\nother\n'), { 'before {# comment #} after' })
check('another tag is not a comment', commented('  I. H\n\n{# hl; fg: red #} red\n'), {})

-- a scope tag on a list item ------------------------------------------------------------------
check(
  'with text around it: the paragraph',
  commented('  I. H\n\n-  item {# comment #}\n-  next\n'),
  { 'item {# comment #}' }
)
check(
  'alone with other contents: the item',
  commented('  I. H\n\n-  {# comment #}\n   para\n-  next\n'),
  { '-  {# comment #}\n   para' }
)
check(
  'alone with a nested list: the item and its list',
  commented('  I. H\n\n-  {# comment #}\n   -  nested\n   -  nested 2\n-  next\n'),
  { '-  {# comment #}\n   -  nested\n   -  nested 2' }
)
check(
  'the only content: the whole list',
  commented('  I. H\n\n-  one\n-  {# comment #}\n-  three\n\ntext\n'),
  { '-  one\n-  {# comment #}\n-  three' }
)

-- a scope tag at the top of the file or a section -------------------------------------------------------
check('the whole file', commented('{# comment #}\n\ntext\n\n  I. H\n\nmore\n'), { '{# comment #}\n\ntext\n\n  I. H\n\nmore' })
local section = commented('  I. H\n\n{# comment #}\n\nbody\n\n  I.A. Sub\n\nsub body\n')
check('a section body, not its subsections', section[1]:find('sub body', 1, true), nil)
check('a section body has its own text', section[1]:find('body', 1, true) ~= nil, true)

-- the index ------------------------------------------------------------------------------------------
local function index(text) return extract.extract(text, { comment_tag = 'comment' }) end
local plain = index('  I. H\n\n{# labels, shown #} {@ date, 2026-10-07 Wed @} {# link, other.fey #}\n\n-  [ ] todo\n')
check('baseline labels', #plain.labels, 1)
check('baseline links', #plain.links, 1)
check('baseline dates', #plain.dates, 1)
check('baseline tasks', #vim.tbl_filter(function(t) return t.kind == 'item' end, plain.tasks), 1)

local hidden = index(
  '  I. H\n\n[ comment #]\n{# labels, hidden #} {@ date, 2026-10-07 Wed @} {# link, other.fey #}\n\n-  [ ] todo\n[# comment ]\n'
)
check('no labels in a comment', #hidden.labels, 0)
check('no links in a comment', #hidden.links, 0)
check('no dates in a comment', #hidden.dates, 0)
check('no tasks in a comment', #vim.tbl_filter(function(t) return t.kind == 'item' end, hidden.tasks), 0)
check('the comment tag itself is indexed', #vim.tbl_filter(function(t) return t.name == 'comment' end, hidden.tags), 1)

local line = index('  I. H\n\n#[ comment ] {@ date, 2026-10-07 Wed @} #\n\n{@ date, 2026-10-08 Thu @}\n')
check('line comment hides only itself', #line.dates, 1)

local file = index('{# comment #}\n\n  I. H {# labels, a #}\n\n{@ date, 2026-10-07 Wed @}\n')
check('a commented file has no labels', #file.labels, 0)

local list = index('  I. H\n\n-  [ ] one\n-  {# comment #}\n-  [ ] three\n\nbreak\n\n-  [ ] outside\n')
check('a commented list has no tasks, another list has', #vim.tbl_filter(function(t) return t.kind == 'item' end, list.tasks), 1)


-- indexing on request -----------------------------------------------------------------------------
local kept = index('  I. H\n\n[ comment, true #]\n{# labels, kept #}\n[# comment ]\n')
check('comment, true keeps indexing', #kept.labels, 1)
local kept_key = index('  I. H\n\n[ comment; index: true #]\n{# labels, kept #}\n[# comment ]\n')
check('index: true keeps indexing', #kept_key.labels, 1)
check('comment, false ignores', #index('  I. H\n\n[ comment, false #]\n{# labels, x #}\n[# comment ]\n').labels, 0)
config:extend({ fey_comment_index_default = true })
check('default true: indexed', #index('  I. H\n\n[ comment #]\n{# labels, x #}\n[# comment ]\n').labels, 1)
check('default true, false still ignores', #index('  I. H\n\n[ comment, false #]\n{# labels, x #}\n[# comment ]\n').labels, 0)
config:extend({ fey_comment_index_default = false })

-- the drawn comment ---------------------------------------------------------------------------------
local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '  I. H', '', '#[ comment ] quiet #', '', 'loud' })
vim.api.nvim_set_current_buf(buf)
vim.bo[buf].filetype = 'fey'
vim.treesitter.start(buf, 'fey')
for _, tag in ipairs(Tag.parse_all_tags(buf)) do
  if tag.name == 'comment' then tag:apply() end
end
local marks = vim.api.nvim_buf_get_extmarks(buf, comment.ns, 0, -1, { details = true })
check('the body is dimmed', { #marks, marks[1] and marks[1][4].hl_group, marks[1] and marks[1][2] }, { 1, 'FeyComment', 2 })
check('commentstring is a line tag', ('#[ %s ] %%s #'):format(config.fey_comment_tag_name), '#[ comment ] %s #')

print(('comments: %d checks, %d failures'):format(total, failures))
vim.cmd(failures == 0 and 'qa!' or 'cq!')
