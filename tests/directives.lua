-- The document data does what org directives did. Run from the repo root:
--
--   FEY_PARSER=/path/to/fey.so nvim --headless --clean -l tests/directives.lua
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
local conf = require('fey.config')
conf:extend({ fey_court_dir = base .. '/court' })
vim.fn.mkdir(base .. '/.fey', 'p')
local fey = require('fey').instance()

local n = 0
local function file_of(lines)
  n = n + 1
  local path = ('%s/n%d.fey'):format(base, n)
  vim.fn.writefile(lines, path)
  vim.cmd('edit! ' .. vim.fn.fnameescape(path))
  vim.bo.filetype = 'fey'
  return fey.files:get_current_file(), path
end

-- no data: the file name and the defaults -----------------------------------------------------------------------
local plain = file_of({ '  I. Nothing', '' })
check('title is the file name', plain:get_title(), 'n1')
check('category too', plain:get_category(), 'n1')
check('the configured todo keywords', plain:get_todo_keywords():find('TODO') ~= nil and plain:get_todo_keywords():find('NEXT') == nil, true)
check('no file labels', plain:get_filetags(), {})
check('no directive properties', plain:get_directive_properties(), {})
check('default header arguments', plain:get_header_args(), conf.fey_babel_default_header_args)
check('no archive of its own', plain:get_archive_file_location():sub(-14), 'n1.fey_archive')

-- data keys ----------------------------------------------------------------------------------------------------------
local f = file_of({
  '{# table; title: Project plan; category: Work; archive: archive/%s_old; header_args: :tangle yes :results output #}',
  '{# table; id: abc-123; author: Ada; todo: TODO NEXT | DONE CANCELLED #}',
  '{# labels, project, plan/2026 #}',
  '',
  '  I. {# status, NEXT #} A step',
  '  II. {# status, CANCELLED #} Dropped',
  '  III. {# status, TODO #} Plain',
  '',
})
check('title', f:get_title(), 'Project plan')
check('category', f:get_category(), 'Work')
check('a key by name', { f:get_directive('author'), f:get_directive('missing') }, { 'Ada', nil })
check('file labels are the labels above the first heading', f:get_filetags(), { 'project', 'plan/2026' })
local keywords = f:get_todo_keywords()
check('the todo keywords of the file', { keywords:find('NEXT') ~= nil, keywords:find('CANCELLED') ~= nil, keywords:find('NEXT').type, keywords:find('CANCELLED').type }, { true, true, 'TODO', 'DONE' })
local headings = f:get_headings()
check('the keywords of the file decide what is a task and what is done', { headings[1]:is_todo(), headings[2]:is_done(), headings[3]:is_todo() }, { true, true, true })
check('the archive location, a template relative to the file', f:get_archive_file_location():sub(-16), '/archive/n2.fey_old' and f:get_archive_file_location():sub(-16))
check('and from the data', f:get_archive_file_location():find('archive/n2.fey_old', 1, true) ~= nil, true)
check('header arguments from the data over the defaults', { f:get_header_args()[':tangle'], f:get_header_args()[':results'] }, { 'yes', 'output' })
check('a property by name', { f:get_directive_property('Author'), f:get_directive_property('header-args'), f:get_directive_property('nothing') }, { 'Ada', ':tangle yes :results output', nil })
check('the scalar keys', f:get_directive_properties().title, 'Project plan')

-- todo as a list: sequences ------------------------------------------------------------------------------------------
local g = file_of({
  '[ table #]',
  'todo_:',
  '    -  TODO NEXT | DONE',
  '    -  OPEN | CLOSED',
  '[# table ]',
  '',
  '  I. {# status, OPEN #} x',
  '',
})
local seq = g:get_todo_keywords()
check('several sequences', { seq:find('NEXT') ~= nil, seq:find('OPEN') ~= nil, seq:find('CLOSED').type }, { true, true, 'DONE' })
check('a heading in the second sequence', g:get_headings()[1]:is_todo(), true)

-- the id of a file ---------------------------------------------------------------------------------------------------------
local h = file_of({ '{# table; title: With id #}', '', '  I. A', '' })
local id = h:id_get_or_create()
check('an id is made as a data key', { h:get_property('id') == id, #id > 0 }, { true, true })
check('and written to the first table tag', vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]:find('id: ' .. id, 1, true) ~= nil, true)
check('asking again gives the same one', h:id_get_or_create(), id)
local id_less = file_of({ '  I. No data at all', '' })
local made = id_less:id_get_or_create()
check('a file without data gets a table tag for it', vim.api.nvim_buf_get_lines(0, 0, 1, false)[1], '{# table; id: ' .. made .. ' #}')

-- completion of the keys ---------------------------------------------------------------------------------------------------------
local Source = require('fey.fey.autocompletion.sources.directives')
local source = Source:new()
local function start(line) return source:get_start({ line = line }) end
check('after the table tag name', start('{# table; ti'), 10)
check('after another key', start('{# table; title: A; ca'), 20)
check('right after the semicolon', start('{# table;'), 9)
check('not in another tag', start('{# status; ti'), nil)
check('not in text', start('table; ti'), nil)
check('not in a closed tag', start('{# table; title: A #} ti'), nil)
local results = source:get_results({})
check('the keys the plugin reads, with their colon', { results[1], vim.tbl_contains(results, 'header_args: '), vim.tbl_contains(results, 'todo: ') }, { 'title: ', true, true })
check('and nothing of org is left', #vim.tbl_filter(function(r) return r:find('#+', 1, true) end, results), 0)

-- the vault ----------------------------------------------------------------------------------------------------------------------------
local vault = require('fey.vault').open(base)
local done = false
vault:scan({}, function() done = true end)
vim.wait(3000, function() return done end, 10)
local rows = vault:query("SELECT f.path, p.name, p.value FROM properties p JOIN files f ON f.id = p.file_id WHERE f.path = 'n2.fey' ORDER BY p.name")
local names = vim.tbl_map(function(r) return r.name end, rows)
check('the document data is in the index', { vim.tbl_contains(names, 'title'), vim.tbl_contains(names, 'todo'), vim.tbl_contains(names, 'header_args'), vim.tbl_contains(names, 'id') }, { true, true, true, true })
check('file labels too', #vault:query("SELECT 1 FROM labels l JOIN files f ON f.id = l.file_id WHERE f.path = 'n2.fey' AND l.heading_ord IS NULL"), 2)

if failures > 0 then
  print(('%d of %d checks failed'):format(failures, total))
  vim.cmd('cquit 1')
end
print(('ok: %d checks'):format(total))
vim.cmd('qa!')
