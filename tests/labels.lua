-- Labels and what holds them. Run from the repo root:
--
--   FEY_PARSER=/path/to/fey.so nvim --headless -u NONE -l tests/labels.lua
vim.opt.rtp:prepend('.')
if vim.env.FEY_PARSER then vim.treesitter.language.add('fey', { path = vim.env.FEY_PARSER }) end
require('fey.config'):extend({ fey_court_dir = vim.fn.tempname() .. '/court' }) -- never the real court

local failures, total = 0, 0
local function check(name, got, want)
  total = total + 1
  if not vim.deep_equal(got, want) then
    failures = failures + 1
    print(('FAIL %s\n  got:  %s\n  want: %s'):format(name, vim.inspect(got), vim.inspect(want)))
  end
end

local extract = require('fey.vault.extract')

local meta = extract.extract(table.concat({
  '{# table; title: T; labels: from_data #}',
  '{# labels, doc #}',
  '',
  '  I. Heading {# labels, in_title #}',
  '{# labels, in_body #}',
  '{# prop; x: 1 #}',
  '',
  'Some text with {# labels, in_text #} inside.',
  '',
  '  I.A. Child',
  '{# table; labels: child_data #}',
  '',
}, '\n'))

local by = {}
for _, l in ipairs(meta.labels) do
  by[l.label] = { l.heading_ord, l.container }
end
check('data key of the document data', by.from_data, { nil, 'data' })
check('label tag above the first heading', by.doc, { nil, 'document' })
check('label tag in a title', by.in_title, { 1, 'title' })
check('label tag in the metadata region', by.in_body, { 1, 'body' })
check('label tag in the text', by.in_text, { 1, 'text' })
check('labels key of a data tag in a heading', by.child_data, { 2, 'data' })
check('line is recorded', meta.labels[2].line, 2)

local regions = {}
for _, t in ipairs(meta.tags) do
  regions[#regions + 1] = t.name .. ':' .. t.region
end
check('tag regions', regions, {
  'table:document', 'labels:document', 'labels:title', 'labels:body', 'prop:body', 'labels:text', 'table:body',
})

-- the index and the query layer ----------------------------------------------------
local root = vim.fn.tempname()
vim.fn.mkdir(root .. '/.fey', 'p')
vim.fn.writefile({
  '{# table; title: A #}', '{# labels, file_label #}', '', '  I. One {# labels, head_label #}', '', 'x', '',
}, root .. '/a.fey')
vim.fn.writefile({ '{# table; title: B #}', '', '  I. Two', '{# labels, only_head #}', '', 'y', '' }, root .. '/b.fey')

require('fey.vault').attach(root, {})
local api = require('fey.api')
local vault = api.current_vault()
check('vault ready', vault:wait(), true)

local a, b = vault:file('a.fey'), vault:file('b.fey')
check('file labels are the labels of the file', a.labels, { 'file_label' })
check('heading labels', a.heading_labels, { 'head_label' })
check('file without file labels', b.labels, {})
check('label rows', vim.tbl_map(function(r) return { r.label, r.container, r.heading_ord } end, a.label_rows), {
  { 'file_label', 'document' }, { 'head_label', 'title', 1 },
})
check('heading object labels', a.headings[1].labels, { 'head_label' })

local function names(rows) return vim.tbl_map(function(r) return r.label end, rows) end
check('all labels of the vault', names(vault:labels()), { 'file_label', 'head_label', 'only_head' })
check('file level labels', names(vault:labels({ level = 'file' })), { 'file_label' })
check('heading level labels', names(vault:labels({ level = 'heading' })), { 'head_label', 'only_head' })
check('labels by container', names(vault:labels({ container = 'body' })), { 'only_head' })

local function column(src)
  local rows = vault:run_query(src).rows
  return rows
end
check('file.labels in a query', column('TABLE file.labels FROM "a.fey"')[1][2], { 'file_label' })
check('file.heading_labels in a query', column('TABLE file.heading_labels FROM "a.fey"')[1][2], { 'head_label' })
check('file.tags counts every label', column('TABLE file.tags FROM "a.fey"')[1][2], { '#file_label', '#head_label' })
check('hash source still finds heading labels', #column('TABLE FROM #only_head'), 1)

if failures > 0 then
  print(('%d of %d checks failed'):format(failures, total))
  vim.cmd('cquit 1')
end
print(('ok: %d checks'):format(total))
vim.cmd('qa!')
