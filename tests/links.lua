-- Links after the consolidation: ids, schemes, bare urls, the first link of a text, broken links, writing links,
-- the references of a heading. Run from the repo root:
--
--   FEY_PARSER=/path/to/fey.so nvim --headless --clean -l tests/links.lua
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
  vim.fn.mkdir(d, 'p')
  return d
end)())
local config = require('fey.config')
require('fey').setup({ fey_court_dir = base .. '/court' })
local links = require('fey.links')
local insert = require('fey.links.insert')

local root = base .. '/hollow'
vim.fn.mkdir(root .. '/.fey', 'p')
local function write(path, lines) vim.fn.writefile(lines, root .. '/' .. path) end
write('target.fey', {
  '{# table; id: file-id-1 #}',
  '',
  '  I. First',
  '',
  '  II. Second',
  '{# prop; id: head-id-2 #}',
  '',
  'text',
})
write('source.fey', {
  '  I. Links',
  '',
  'ok {@ link, target.fey; section: II. @}',
  'file gone {@ link, missing.fey @}',
  'section gone {@ link, target.fey; section: IX. @}',
  'id ok {@ link, id:head-id-2 @}',
  'id gone {@ link, id:nobody @}',
  'web {@ link, https://example.com/a @}',
  'section tag {@ section, II., target.fey @}',
})

local registry = require('fey.vault')
local vault = registry.open(root)
local done = false
vault:scan({}, function() done = true end)
vim.wait(5000, function() return done end, 10)

-- ids -------------------------------------------------------------------------------------------
local hit = vault:find_id('head-id-2')
check('a heading by its id', { hit.path, hit.signature, hit.line }, { 'target.fey', 'II.', 5 })
hit = vault:find_id('file-id-1')
check('a file by its id', hit.path, 'target.fey')
check('nothing by an unknown id', vault:find_id('nobody'), nil)
vim.cmd('edit! ' .. vim.fn.fnameescape(root .. '/source.fey'))
check('following an id opens the heading', { links.goto_id('head-id-2', root .. '/source.fey'), vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ':t'), vim.api.nvim_win_get_cursor(0)[1] }, { true, 'target.fey', 5 })

-- broken links ------------------------------------------------------------------------------------
local broken = vault:broken_links()
local summary = vim.tbl_map(function(b) return b.line .. ':' .. b.reason end, broken)
check('broken links: a file, a section, an id; not the urls, ids and sections that exist', summary, { '4:file', '5:section', '7:id' })
local rows = require('fey.links.check').run('current', root)
check('into quickfix', { #rows, #vim.fn.getqflist() }, { 3, 3 })
vim.cmd('cclose')

-- the first link of a text, a bare url ----------------------------------------------------------------
check('first link of a text', links.first_link_in('Write {@ link, notes/a.fey; section: I.A. @} and {@ link, b.fey @}'), { target = 'notes/a.fey', sig = 'I.A.', n = nil })
check('a section tag', links.first_link_in('see {@ section, II., b.fey @}'), { sig = 'II.', target = 'b.fey' })
check('no link', links.first_link_in('nothing {# status, TODO #} here'), nil)
vim.bo.modified = false
vim.cmd('enew')
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'go to https://example.com/page, then' })
vim.api.nvim_win_set_cursor(0, { 1, 12 })
check('a bare url under the cursor', links.url_at_cursor(), 'https://example.com/page')
vim.api.nvim_win_set_cursor(0, { 1, 1 })
check('not on it', links.url_at_cursor(), nil)

-- schemes ---------------------------------------------------------------------------------------------
local seen
config:extend({ fey_link_schemes = { jira = function(target) seen = target end } })
links.open_target('jira:ABC-1', nil, nil, root .. '/source.fey')
check('a scheme of the setup handles its links', seen, 'ABC-1')
config:extend({ fey_link_schemes = {} })

-- writing links -----------------------------------------------------------------------------------------
vim.cmd('edit! ' .. vim.fn.fnameescape(root .. '/target.fey'))
vim.bo.filetype = 'fey'
vim.treesitter.start(0, 'fey')
check('link text with a section', insert.link_text({ path = root .. '/target.fey', signature = 'II.', title = 'Second' }), '{@ link, target.fey; desc: Second; section: II. @}')
check('link text with an id', insert.link_text({ path = root .. '/target.fey', title = 'Second', id = 'head-id-2' }), '{@ link, id:head-id-2; desc: Second @}')
check('link text with a chosen description', insert.link_text({ path = root .. '/target.fey', title = 'x' }, 'the word'), '{@ link, target.fey; desc: the word @}')
local FeyFile = require('fey.files.file')
local file = FeyFile:new({ filename = root .. '/target.fey', buf = vim.api.nvim_get_current_buf() })
local stored = insert.store(file:get_closest_heading({ 5, 0 }))
check('a stored heading', { stored.title, stored.signature, stored.path }, { 'Second', 'II.', root .. '/target.fey' })
insert.store(file:get_closest_heading({ 3, 0 }))
check('stored, the newest first', { #insert.stored, insert.stored[1].title }, { 2, 'First' })
insert.store(file:get_closest_heading({ 5, 0 }))
check('stored again moves it up, once', { #insert.stored, insert.stored[1].title }, { 2, 'Second' })
config:extend({ fey_id_link_to_fey_use_id = true })
local with_id = insert.store(file:get_closest_heading({ 5, 0 }))
check('with ids, the heading has one', with_id.id, 'head-id-2')
config:extend({ fey_id_link_to_fey_use_id = false })

-- references (the LSP handler) ---------------------------------------------------------------------------
local handlers = require('fey.lsp.handlers')
local refs = handlers[vim.lsp.protocol.Methods.textDocument_references]({
  textDocument = { uri = vim.uri_from_fname(root .. '/target.fey') },
  position = { line = 4, character = 0 },
})
check('references of a heading', vim.tbl_map(function(l) return vim.fn.fnamemodify(vim.uri_to_fname(l.uri), ':t') .. ':' .. (l.range.start.line + 1) end, refs), { 'source.fey:3', 'source.fey:9' })

-- completion ----------------------------------------------------------------------------------------------
local Source = require('fey.fey.autocompletion.sources.hyperlinks')
local source = Source:new({ completion = {} })
check('completion starts in the target of a link tag', source:get_start({ line = 'see {@ link, tar' }), 13)
check('and not elsewhere', source:get_start({ line = 'see {@ date, tar' }), nil)
vim.cmd('edit! ' .. vim.fn.fnameescape(root .. '/source.fey'))
local results = source:get_results({ base = 'tar', matcher = function(item, base) return item:find(base, 1, true) ~= nil end })
check('completion lists the files', results, { 'target.fey' })

vault:close()
print(('links: %d checks, %d failures'):format(total, failures))
vim.cmd(failures == 0 and 'qa!' or 'cq!')
