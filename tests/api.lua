-- Lua API tests. Run from the repo root:
--
--   FEY_PARSER=/path/to/fey.so nvim --headless -u NONE -l tests/api.lua
vim.opt.rtp:prepend('.')
if vim.env.FEY_PARSER then vim.treesitter.language.add('fey', { path = vim.env.FEY_PARSER }) end
require('fey.config'):extend({})

local failures, total = 0, 0
local function check(name, got, want)
  total = total + 1
  if not vim.deep_equal(got, want) then
    failures = failures + 1
    print(('FAIL %s\n  got:  %s\n  want: %s'):format(name, vim.inspect(got), vim.inspect(want)))
  end
end

local root = vim.fn.tempname()
vim.fn.mkdir(root .. '/.fey', 'p')
vim.fn.mkdir(root .. '/notes', 'p')
vim.fn.writefile({
  '{# table; title: Alpha; rating: 4; status: open #}', '{# labels, design #}', '', '  I. Alpha', '', 'x', '', '  I.A. Sub', '', 'y',
}, root .. '/notes/alpha.fey')
vim.fn.writefile({
  '{# table; title: Beta; rating: 2 #}', '{# labels, markup #}', '', '  I. Beta', '', 'see {@ section, I.A., notes/alpha.fey @}',
}, root .. '/notes/beta.fey')

local registry = require('fey.vault')
registry.attach(root, {})
local api = require('fey.api')
local vault = api.current_vault()
check('vault found', vault ~= nil, true)
check('vault ready', vault:wait(), true)

local alpha = vault:file('notes/alpha.fey')
check('title', alpha.title, 'Alpha')
-- headings are keys of the document data (README section VII.C); `Alpha` holds its subsection `Sub`
check('data', alpha.data, { title = 'Alpha', rating = 4, status = 'open', Alpha = {} })
check('labels', alpha.labels, { 'design' })
check('headings', vim.tbl_map(function(h) return h.signature end, alpha.headings), { 'I.', 'I.A.' })
check('heading parent', alpha.headings[2]:parent().title, 'Alpha')
check('heading children', #alpha.headings[1]:children(), 1)
check('absolute lookup', vault:file(root .. '/notes/alpha.fey').path, 'notes/alpha.fey')
check('backlinks of heading', #alpha.headings[2]:backlinks(), 1)
check('backlinks ignore delimiters', #vault:backlinks('notes/alpha.fey', 'I,A,'), 1)
check('files with label', #vault:files_with_label('design'), 1)
check('files with property', #vault:files_with_property('status', 'open'), 1)

check('set property', alpha:set_property('rating', 5), true)
check('property updated', alpha:property('rating'), 5)
check('add label', alpha:add_label('extra'), true)
check('labels after add', alpha.labels, { 'design', 'extra' })
check('remove label', alpha:remove_label('extra'), true)
check('remove property', alpha:remove_property('status'), true)
check('property removed', alpha:property('status'), nil)

local result = vault:run_query('TABLE rating FROM #design')
check('query', { result.type, result.count }, { 'table', 1 })
check('query lines', api.query_lines('LIST FROM #markup'), { '-  {@ link, notes/beta.fey @}' })
check('link text', api.link_text('notes/a.fey', { desc = 'A, b', section = 'I.' }), '{@ link, notes/a.fey; desc: A\\, b; section: I. @}')
check('section text', api.section_text('I.A.', 'notes/a.fey', 2), '{@ section, I.A., notes/a.fey, 2 @}')

local seen
api.on('file_indexed', function(data) seen = data.path end)
alpha:set_property('rating', 6)
vim.wait(100)
check('event', seen, 'notes/alpha.fey')

vim.fn.delete(root, 'rf')
print(('%d checks, %d failed'):format(total, failures))
vim.cmd(failures == 0 and 'qa!' or 'cquit 1')
