-- Completion inside the head of a tag. Run from the repo root:
--
--   FEY_PARSER=/path/to/fey.so nvim --headless --clean -l tests/completion.lua
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
local ctx = require('fey.fey.autocompletion.tag_context')

-- where the cursor is ---------------------------------------------------------------------------
local function at(line)
  local c = ctx.parse(line)
  if not c then return nil end
  return { c.kind, c.tag, c.index, c.key, c.base, c.start }
end
check('no tag', at('just some text'), nil)
check('a closed tag', at('{# status, TODO #} and so on'), nil)
check('a name', at('{# sta'), { 'name', nil, nil, nil, 'sta', 3 })
check('a name after text', at('word {@ da'), { 'name', nil, nil, nil, 'da', 8 })
check('a name of a line tag', at('#[ hl'), { 'name', nil, nil, nil, 'hl', 3 })
check('a name of a block tag', at('[ que'), { 'name', nil, nil, nil, 'que', 2 })
check('a closer is not a tag', at('[# que'), nil)
check('the first value', at('{# status, TO'), { 'value', 'status', 1, nil, 'TO', 11 })
check('the first value, nothing typed', at('{# status, '), { 'value', 'status', 1, nil, '', 11 })
check('the second value', at('{# status, TODO, '), { 'value', 'status', 2, nil, '', 17 })
check('blanks after the name', at('{# status '), { 'value', 'status', 1, nil, '', 10 })
check('a key', at('{# date, 2026-10-07; ac'), { 'key', 'date', nil, nil, 'ac', 21 })
check('a key, nothing typed', at('{# link, a.fey; '), { 'key', 'link', nil, nil, '', 16 })
check('a second key', at('{# clock, a; end: b; d'), { 'key', 'clock', nil, nil, 'd', 21 })
check('the value of a key', at('{# link, a.fey; section: I'), { 'key_value', 'link', nil, 'section', 'I', 25 })
check('the value of a key, nothing typed', at('{# query, LIST; scope: '), { 'key_value', 'query', nil, 'scope', '', 23 })
check('an escaped comma is not a delimiter', at('{# link, a\\,b, c'), { 'value', 'link', 2, nil, 'c', 15 })
check('a pair tag', at('[ query_result; con'), { 'key', 'query_result', nil, nil, 'con', 16 })
check('a block tag value', at('[ clocktable, th'), { 'value', 'clocktable', 1, nil, 'th', 14 })
check('values are collected', ctx.parse('{# status, TODO, A; pri').values, { 'TODO', 'A' })

-- what is offered ----------------------------------------------------------------------------------
local root = base .. '/hollow'
vim.fn.mkdir(root .. '/.fey', 'p')
vim.fn.writefile({ '{# table; id: a1 #}', '{# labels, design, work #}', '', '  I. First', '', '  II. Second {# labels, home #}', '', 'x {# fn, one #} {# weird, a; colour: red #}', '', '[ fn, one #]', 'note', '[# fn ]' }, root .. '/target.fey')
vim.fn.writefile({ '  I. Source', '', '{@ link, target.fey @}' }, root .. '/source.fey')
local vault = require('fey.vault').open(root)
local done = false
vault:scan({}, function() done = true end)
vim.wait(5000, function() return done end, 10)
vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/source.fey'))

local fey = require('fey')
local function offered(line, base_text)
  local results = fey.completion:complete({ line = line, base = base_text or '', fuzzy = false })
  return vim.tbl_map(function(r) return r.word end, results)
end
local function has(list, item) return vim.tbl_contains(list, item) end

local names = offered('{# ', '')
check('names: the plugin ones', { has(names, 'status'), has(names, 'clocktable'), has(names, 'comment'), has(names, 'math') }, { true, true, true, true })
check('names: the ones written in the notes', has(names, 'weird'), true)
check('names are filtered by what is typed', offered('{# cl', 'cl'), { 'clock', 'clocktable', 'clocktable_result', 'closed' })

local todo = offered('{# status, ', '')
check('todo keywords', { has(todo, 'TODO'), has(todo, 'DONE') }, { true, true })
check('priorities after the keyword', offered('{# status, TODO, ', ''), { 'A', 'B', 'C' })
local labels = offered('{# labels, ', '')
check('labels from the index', { has(labels, 'design'), has(labels, 'home') }, { true, true })
check('files for a link', offered('{@ link, ', ''), { 'source.fey', 'target.fey' })
check('keys of a link', offered('{@ link, target.fey; ', ''), { 'desc: ', 'section: ', 'n: ', 'conceal: ' })
check('headings for the section key', offered('{@ link, target.fey; section: ', ''), { 'I.', 'II.' })
check('signatures for a section tag', offered('{@ section, ', ''), { 'I.' })
check('keys of a clock tag', offered('{@ clock, 2026; ', ''), { 'end: ', 'dur: ' })
check('keys written in the notes', has(offered('{# weird, a; ', ''), 'colour: '), true)
check('values of by', offered('{# clocktable; by: ', ''), { 'heading', 'file', 'day' })
check('spans', has(offered('{# clocktable, ', ''), 'thisweek'), true)
check('booleans', offered('{# query, LIST; conceal: ', ''), { 'true', 'false' })
check('scope', offered('{# query, LIST; scope: ', ''), { 'current', 'tree', 'court' })
check('footnote labels', offered('{@ fn, ', ''), { 'one' })
check('the keys of the document data', has(offered('{# table; ', ''), 'title: '), true)
check('options for the nvim tag', has(offered('{# nvim; wra', 'wra'), 'wrap: '), true)
check('hot options for the plugin tag', has(offered('{# plugin, fey; fey_query_conc', 'fey_query_conc'), 'fey_query_conceal_default: '), true)
check('a plugin name', has(offered('{# plugin, ', ''), 'fey'), true)
check('nothing outside a tag', offered('plain words', 'plain'), {})

-- the omnifunc and the other adapters -------------------------------------------------------------------------
vim.api.nvim_buf_set_lines(0, 0, -1, false, { '{# status, TO' })
vim.api.nvim_win_set_cursor(0, { 1, 12 })
check('omnifunc finds the start', fey.completion:omnifunc(1, ''), 11)
check('omnifunc completes', vim.tbl_map(function(r) return r.word end, fey.completion:omnifunc(0, 'TO')), { 'TODO' })
check('no start outside a tag', fey.completion:get_start({ line = 'text' }), -1)
local lsp = require('fey.lsp.handlers')[vim.lsp.protocol.Methods.textDocument_completion]
local result = lsp({ textDocument = { uri = vim.uri_from_bufnr(0) }, position = { line = 0, character = 12 } })
check('lsp completion', { #result.items, result.items[1].textEdit.range.start.character }, { 1, 11 })

vault:close()
print(('completion: %d checks, %d failures'):format(total, failures))
vim.cmd(failures == 0 and 'qa!' or 'cq!')
