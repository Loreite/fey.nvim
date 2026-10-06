-- Todo keyword, priority, title and labels of headings, and how they are shown. Run from the repo root:
--
--   FEY_PARSER=/path/to/fey.so nvim --headless --clean -l tests/heading_task.lua
vim.opt.rtp:prepend('.')
if vim.env.FEY_PARSER then vim.treesitter.language.add('fey', { path = vim.env.FEY_PARSER }) end
require('fey.config'):extend({})
require('fey.config'):setup_ts_predicates()

local FeyFile = require('fey.files.file')
local Tag = require('fey.files.elements.tags')

local failures, total = 0, 0
local function check(name, got, want)
  total = total + 1
  if not vim.deep_equal(got, want) then
    failures = failures + 1
    print(('FAIL %s\n  got:  %s\n  want: %s'):format(name, vim.inspect(got), vim.inspect(want)))
  end
end

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, 'p')
local n = 0
local function open(lines)
  n = n + 1
  local name = ('%s/t%d.fey'):format(dir, n)
  vim.fn.writefile(lines, name)
  vim.cmd('edit ' .. vim.fn.fnameescape(name))
  local buf = vim.api.nvim_get_current_buf()
  vim.b[buf].did_ftplugin = true
  vim.bo[buf].filetype = 'fey'
  vim.treesitter.start(buf, 'fey')
  return buf, FeyFile:new({ filename = name, buf = buf })
end
local function lines(buf) return vim.api.nvim_buf_get_lines(buf, 0, -1, false) end
local function sorted(t) local c = vim.deepcopy(t); table.sort(c); return c end

-- reading -----------------------------------------------------------------------
local buf, file = open({
  '  I. {# status, TODO, A #} Write the report {# labels, work, urgent #}',
  '',
  '  I.A. Plain child',
  '',
  '  I.B. Not first {# status, TODO #}',
  '',
  '  I.C. {# status; priority: B #} Only a priority',
  '',
})
local h, child, late, prio = file:get_closest_heading({ 1, 0 }), file:get_closest_heading({ 3, 0 }), file:get_closest_heading({ 5, 0 }), file:get_closest_heading({ 7, 0 })
local keyword, node, kind, index = h:get_todo()
check('todo keyword', { keyword, node and node:type(), kind, index }, { 'TODO', 'scope_tag', 'TODO', 1 })
check('is_todo', { h:is_todo(), h:is_done() }, { true, false })
check('priority is the second value', (h:get_priority()), 'A')
check('title without its metadata', (h:get_title()), 'Write the report')
check('own labels', (h:get_own_tags()), { 'work', 'urgent' })
check('no status', { child:get_todo(), (child:get_priority()) }, { nil, '' })
check('plain title', (child:get_title()), 'Plain child')
check('labels are inherited', sorted((child:get_tags())), { 'urgent', 'work' })
check('a status tag that is not first is not read', { late:get_todo(), (late:get_priority()) }, { nil, '' })
check('title of a heading with a stray status tag', (late:get_title()), 'Not first')
check('a priority without a keyword is the priority key', { prio:get_todo(), (prio:get_priority()) }, { nil, 'B' })
check('title of a priority only heading', (prio:get_title()), 'Only a priority')

-- writing -----------------------------------------------------------------------
h:set_todo('DONE')
check('set_todo replaces the keyword, keeps the priority', lines(buf)[1]:match('^  I%. (.-) Write'), '{# status, DONE, A #}')
h = file:get_closest_heading({ 1, 0 })
check('is_done after', h:is_done(), true)
h:set_todo('')
check('without a keyword the priority becomes a key', lines(buf)[1], '  I. {# status; priority: A #} Write the report {# labels, work, urgent #}')
h = file:get_closest_heading({ 1, 0 })
check('still has its priority', (h:get_priority()), 'A')
h:set_todo('TODO')
check('a keyword comes first, the priority after it', lines(buf)[1], '  I. {# status, TODO, A #} Write the report {# labels, work, urgent #}')
h = file:get_closest_heading({ 1, 0 })
h:set_priority('')
check('removing the priority keeps the keyword', lines(buf)[1], '  I. {# status, TODO #} Write the report {# labels, work, urgent #}')
h = file:get_closest_heading({ 1, 0 })
h:set_priority('A')
check('and it comes back', lines(buf)[1], '  I. {# status, TODO, A #} Write the report {# labels, work, urgent #}')

child = file:get_closest_heading({ 3, 0 })
child:set_priority('B')
check('a priority without a keyword is a key', lines(buf)[3], '  I.A. {# status; priority: B #} Plain child')
child = file:get_closest_heading({ 3, 0 })
child:set_todo('TODO')
check('the keyword takes the front', lines(buf)[3], '  I.A. {# status, TODO, B #} Plain child')
child = file:get_closest_heading({ 3, 0 })
child:set_priority('C')
check('priority replaced', lines(buf)[3], '  I.A. {# status, TODO, C #} Plain child')
child = file:get_closest_heading({ 3, 0 })
child:set_priority('')
check('priority removed', lines(buf)[3], '  I.A. {# status, TODO #} Plain child')
child = file:get_closest_heading({ 3, 0 })
child:set_todo('')
check('nothing left removes the tag', lines(buf)[3], '  I.A. Plain child')
child = file:get_closest_heading({ 3, 0 })
child:set_todo('TODO')
child = file:get_closest_heading({ 3, 0 })
child:set_priority('A')
check('priority after the keyword', lines(buf)[3], '  I.A. {# status, TODO, A #} Plain child')
child = file:get_closest_heading({ 3, 0 })
check('title after all this', (child:get_title()), 'Plain child')

-- other keys of the tag stay
buf, file = open({ '  I. {# status, TODO; at: 2026-10-06 #} Keep' })
h = file:get_closest_heading({ 1, 0 })
h:set_priority('B')
check('other keys are kept', lines(buf)[1], '  I. {# status, TODO, B; at: 2026-10-06 #} Keep')
h = file:get_closest_heading({ 1, 0 })
h:set_todo('DONE')
check('and kept again', lines(buf)[1], '  I. {# status, DONE, B; at: 2026-10-06 #} Keep')

buf, file = open({
  '  I. {# status, TODO, A #} Write the report {# labels, work, urgent #}',
  '',
  '  I.A. {# status, TODO, A #} Plain child',
  '',
})
h, child = file:get_closest_heading({ 1, 0 }), file:get_closest_heading({ 3, 0 })

-- labels
child:set_tags({ 'x', 'y' })
check('set_tags adds a labels tag at the end of the title', lines(buf)[3], '  I.A. {# status, TODO, A #} Plain child {# labels, x, y #}')
child = file:get_closest_heading({ 3, 0 })
child:set_tags('x z')
check('set_tags rewrites it, a string works too', lines(buf)[3]:match('{# labels, [^#]*#}'), '{# labels, x, z #}')
child = file:get_closest_heading({ 3, 0 })
check('add_tag', child:add_tag('w'), true)
child = file:get_closest_heading({ 3, 0 })
check('add_tag again', child:add_tag('w'), false)
check('labels after add', (child:get_own_tags()), { 'x', 'z', 'w' })
check('toggle off', child:toggle_tag('z'), false)
child = file:get_closest_heading({ 3, 0 })
check('remove_tag', child:remove_tag('x'), true)
child = file:get_closest_heading({ 3, 0 })
check('labels after the edits', (child:get_own_tags()), { 'w' })
check('is_archived', child:is_archived(), false)
child:set_tags({})
check('no labels removes the tag', lines(buf)[3], '  I.A. {# status, TODO, A #} Plain child')

-- labels in the tag lines under the heading are read and rewritten in place
buf, file = open({ '  I. Head', '{# labels, a, b #}', '', 'text', '' })
h = file:get_closest_heading({ 1, 0 })
check('labels in the body region', (h:get_own_tags()), { 'a', 'b' })
h:set_tags({ 'c' })
check('rewritten where they are', { lines(buf)[1], lines(buf)[2] }, { '  I. Head', '{# labels, c #}' })

-- document data: todo keywords, title, labels of the file -----------------------------
buf, file = open({
  '{# table; title: My notes; todo: TODO NEXT | DONE; category: work #}',
  '{# labels, filelabel #}',
  '',
  '  I. {# status, NEXT #} Do it',
  '',
})
check('keywords of the document', vim.tbl_map(function(k) return k.value end, file:get_todo_keywords().todo_keywords), { 'TODO', 'NEXT', 'DONE' })
check('file title', file:get_title(), 'My notes')
check('file category', file:get_category(), 'work')
check('file labels', file:get_filetags(), { 'filelabel' })
h = file:get_closest_heading({ 4, 0 })
local doc_keyword, _, doc_kind, doc_index = h:get_todo()
check('a keyword from the document', { doc_keyword, doc_kind, doc_index }, { 'NEXT', 'TODO', 2 })
check('heading inherits file labels', (h:get_tags()), { 'filelabel' })

-- properties --------------------------------------------------------------------
buf, file = open({
  '{# table; title: P #}',
  '',
  '  I. Parent',
  '{# prop; effort: 2h; category: work #}',
  '',
  '  I.A. Child',
  '',
})
h, child = file:get_closest_heading({ 3, 0 }), file:get_closest_heading({ 6, 0 })
check('own properties', (h:get_own_properties()), { effort = '2h', category = 'work' })
check('get_property', (h:get_property('effort')), '2h')
check('get_property is case insensitive', (h:get_property('Effort')), '2h')
check('a heading without properties', (child:get_own_properties()), {})
check('category is a property', h:get_category(), 'work')
check('the category is inherited from a parent heading', child:get_category(), 'work')
check('get_property searching parents', (child:get_property('effort', true)), '2h')
check('get_property not searching parents', (child:get_property('effort', false)), nil)

h:set_property('effort', '3h')
check('set_property replaces', lines(buf)[4], '{# prop; effort: 3h; category: work #}')
h = file:get_closest_heading({ 3, 0 })
h:set_property('id', 'a-b')
check('set_property adds a key to the tag', lines(buf)[4], '{# prop; effort: 3h; category: work; id: a-b #}')
h = file:get_closest_heading({ 3, 0 })
h:set_property('header-args', ':tangle yes')
check('names are normalised', lines(buf)[4]:match('header_args: [^;#]*'), 'header_args: :tangle yes ')
check('and read back', (file:get_closest_heading({ 3, 0 }):get_property('header-args')), ':tangle yes')
h = file:get_closest_heading({ 3, 0 })
h:set_property('note', 'a, b; c')
check('values are escaped and read back', (file:get_closest_heading({ 3, 0 }):get_property('note')), 'a, b; c')
h = file:get_closest_heading({ 3, 0 })
h:set_property('note', nil)
h = file:get_closest_heading({ 3, 0 })
h:set_property('header-args', nil)
h = file:get_closest_heading({ 3, 0 })
h:set_property('id', nil)
check('set_property with nil removes the key', lines(buf)[4], '{# prop; effort: 3h; category: work #}')

child = file:get_closest_heading({ 6, 0 })
child:set_property('effort', '1h')
check('a new tag line under the heading', { lines(buf)[6], lines(buf)[7] }, { '  I.A. Child', '{# prop; effort: 1h #}' })
child = file:get_closest_heading({ 6, 0 })
child:set_property('effort', nil)
check('removing the last key removes the tag', { lines(buf)[6], lines(buf)[7] }, { '  I.A. Child', '' })

-- the properties of the file are the document data
check('file properties', (file:get_properties()), { title = 'P' })
check('file property', (file:get_property('title')), 'P')
file:set_property('status', 'open')
check('set a file property', lines(buf)[1], '{# table; title: P; status: open #}')
file:set_property('title', nil)
check('remove a file property', lines(buf)[1], '{# table; status: open #}')
file:set_property('status', nil)
check('removing the last one removes the tag', lines(buf)[1], '')
file:set_property('id', 'x1')
check('a file property creates the tag', lines(buf)[1], '{# table; id: x1 #}')

-- handlers ----------------------------------------------------------------------
Tag.setup({})
check('status handler', type(Tag.handlers.status.scope_tag), 'function')
check('open at point', { Tag.at_point.status, Tag.at_point.date, Tag.at_point.labels, Tag.at_point.todo }, { true, true, nil, nil })

-- concealment -------------------------------------------------------------------
buf = open({ '  I. {# status, TODO, A #} Write {# labels, work, urgent #}', '  I.A. {# status; priority: B #} Prio', '  I.B. {# status, DONE #} Done', '' })
local TaskTags = require('fey.colors.highlighter.task_tags')
local ns = vim.api.nvim_create_namespace('fey_test_task_tags')
local hl = TaskTags:new({ highlighter = { namespace = ns } })
hl.ephemeral = false
local tree = vim.treesitter.get_parser(buf, 'fey'):parse()[1]
local function marks(row)
  row = row or 0
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  hl:on_line(buf, row, tree)
  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
  local concealed, shown = {}, {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, { row, 0 }, { row, -1 }, { details = true })) do
    local d = m[4]
    local piece = line:sub(m[3] + 1, d.end_col)
    if d.conceal then concealed[#concealed + 1] = piece elseif d.hl_group then shown[#shown + 1] = { piece, d.hl_group } end
  end
  return concealed, shown
end
local concealed, shown = marks()
check('concealed parts', concealed, { '{# status, ', ',', ' #}', '{# labels, ', ' #}' })
check('shown values', vim.tbl_map(function(s) return s[1] end, shown), { 'TODO', ' A', 'work, urgent' })
check('faces', vim.tbl_map(function(s) return s[2] end, shown), { '@fey.keyword.todo', '@fey.priority.highest', '@fey.tag' })

concealed, shown = marks(1)
check('priority key: concealed', concealed, { '{# status; priority: ', ' #}' })
check('priority key: shown', shown, { { 'B', '@fey.priority.default' } })
concealed, shown = marks(2)
check('keyword only: concealed', concealed, { '{# status, ', ' #}' })
check('keyword only: face of a done keyword', shown, { { 'DONE', '@fey.keyword.done' } })

vim.b[buf].fey_conceal_task_tags = false
check('switched off per buffer', { marks() }, { {}, {} })
vim.b[buf].fey_conceal_task_tags = nil
require('fey.config').fey_conceal_task_tags = false
check('switched off by the option', { marks() }, { {}, {} })
vim.b[buf].fey_conceal_task_tags = true
check('the buffer overrides the option', #marks() > 0, true)
require('fey.config').fey_conceal_task_tags = true
vim.b[buf].fey_conceal_task_tags = nil

-- the toggle flips the buffer variable
local mappings = setmetatable({}, { __index = require('fey.fey.mappings') })
mappings:toggle_conceal_task_tags()
check('toggle off', vim.b[buf].fey_conceal_task_tags, false)
mappings:toggle_conceal_task_tags()
check('toggle on', vim.b[buf].fey_conceal_task_tags, true)

if failures > 0 then
  print(('%d of %d checks failed'):format(failures, total))
  vim.cmd('cquit 1')
end
print(('ok: %d checks'):format(total))
vim.cmd('qa!')
