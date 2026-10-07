-- The agenda reads the vaults of a scope. Run from the repo root:
--
--   FEY_PARSER=/path/to/fey.so nvim --headless --clean -l tests/agenda.lua
vim.opt.rtp:prepend('.')
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
require('fey.config'):extend({ fey_court_dir = base .. '/feyhollow' })

local tree = require('fey.hollow.tree')
local court = require('fey.hollow.court')
local registry = require('fey.vault')
local Date = require('fey.objects.date')
local Source = require('fey.agenda.source')
local AgendaFilter = require('fey.agenda.filter')
local Agenda = require('fey.agenda.types.agenda')

local function write(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  vim.fn.writefile(lines, path)
end
local function scan(root)
  local vault = registry.open(root)
  local done = false
  vault:scan({}, function() done = true end)
  vim.wait(3000, function() return done end, 10)
end

local today = Date.today()
local function day(offset) return today:add({ day = offset }) end
local function stamp(offset) return day(offset):format('%Y-%m-%d %a') end

court.ensure_dirs()
local alpha, child, beta = base .. '/alpha', base .. '/alpha/child', base .. '/beta'
write(alpha .. '/.fey/x', {})
write(alpha .. '/a.fey', {
  '{# table; category: Work #}',
  '{# labels, projectx #}',
  '  I. {# status, TODO, A #} Write report {# labels, office #}',
  '{# scheduled, ' .. stamp(0) .. ' #}',
  '{# deadline, ' .. stamp(2) .. ' #}',
  '',
  '  II. {# status, DONE #} Finished thing',
  '{# scheduled, ' .. stamp(0) .. ' #}',
  '',
  '  III. Plain note with a date {@ date, ' .. stamp(1) .. ' 10:00 @}',
  '',
  '  IV. {# status, TODO #} Weekly chore',
  '{# scheduled, ' .. stamp(-14) .. ' +1w #}',
  '',
  '  V. {# status, TODO #} Old and unfinished',
  '{# scheduled, ' .. stamp(-3) .. ' #}',
  '',
})
write(child .. '/.fey/x', {})
write(child .. '/c.fey', {
  '  I. {# status, TODO #} Child item {# labels, home #}',
  '{# scheduled, ' .. stamp(0) .. ' #}',
  '',
  '  II. Notes {# labels, parentlabel #}',
  '',
  'remember the milk',
  '',
  '  II.A. {# status, TODO, C #} Nested task',
  '{# prop; effort: 2 #}',
  '',
  'nothing about dairy here',
  '',
})
write(beta .. '/.fey/x', {})
write(beta .. '/b.fey', { '  I. {# status, TODO #} Beta item {# labels, big-ish #}', '{# deadline, ' .. stamp(0) .. ' #}', '' })
for _, root in ipairs({ alpha, child, beta }) do
  tree.register_chain(root)
  scan(root)
end
vim.fn.delete(alpha .. '/.fey/x')

local function view(opts)
  return Agenda:new(vim.tbl_extend('force', {
    source = Source.new({ scope = 'court' }),
    agenda_filter = AgendaFilter:new(),
    span = 'week',
    from = today,
    start_on_weekday = false,
  }, opts or {}))
end
local function titles(days, i)
  return vim.tbl_map(function(item) return item.heading:get_title() end, days[i].agenda_items)
end
local function sorted(list)
  table.sort(list)
  return list
end

-- the entries -------------------------------------------------------------------------------------------
local source = Source.new({ scope = 'court' })
local items = source:dates(today, day(7))
check('dates of every hollow', #items > 0, true)
local by_title = {}
for _, item in ipairs(items) do
  by_title[item.entry:get_title()] = item.entry
end
local report = by_title['Write report']
check('title without the metadata tags', report ~= nil, true)
check('todo', { report:get_todo() }, { 'TODO', nil, 'TODO', 1 })
check('priority', report:get_priority(), 'A')
check('priority sort value is set', report:get_priority_sort_value() > by_title['Weekly chore']:get_priority_sort_value(), true)
check('labels are the tags: own and of the document', report:get_tags(), { 'office', 'projectx' })
check('has tag', { report:has_tag('office'), report:has_tag('home') }, { true, false })
check('category of the document', report:get_category(), 'Work')
check('category of a document without one is its name', by_title['Child item']:get_category(), 'c')
check('done', { by_title['Finished thing']:is_done(), report:is_done() }, { true, false })
check('the hollow', { report.hollow, by_title['Child item'].hollow, by_title['Beta item'].hollow }, { 'court:alpha', 'court:alpha:child', 'court:beta' })
check('where it lives', { report.path, report.line, report.abs }, { 'a.fey', 3, alpha .. '/a.fey' })

-- days of a view ----------------------------------------------------------------------------------------
local v = view()
local days = v:_get_agenda_days()
check('seven days', #days, 7)
check('today', sorted(titles(days, 1)), { 'Beta item', 'Child item', 'Finished thing', 'Old and unfinished', 'Weekly chore', 'Write report', 'Write report' })
check('tomorrow has the dated note', #titles(days, 2), 1)
check('with the title as written', titles(days, 2)[1]:match('^Plain note with a date'), 'Plain note with a date')
check('a deadline shows ahead of time today', vim.tbl_contains(titles(days, 1), 'Write report'), true)
check('and on its day', vim.tbl_contains(titles(days, 3), 'Write report'), true)
local labels = {}
for _, item in ipairs(days[1].agenda_items) do
  if item.heading:get_title() == 'Weekly chore' then labels[#labels + 1] = item.label end
end
check('a repeating date repeats onto the week', #labels, 1)
check('and keeps repeating a week later', vim.tbl_contains(titles(view({ span = 14 }):_get_agenda_days(), 8), 'Weekly chore'), true)
check('an overdue scheduled item stays on', vim.tbl_contains(titles(days, 1), 'Old and unfinished'), true)
check('but not on a later day it was done with', vim.tbl_contains(titles(days, 2), 'Finished thing'), false)
check('time of a date', (function()
  for _, item in ipairs(days[2].agenda_items) do
    if item.heading:get_title():match('^Plain note') then return item.label end
  end
end)():match('^10:00'), '10:00')

-- scopes ------------------------------------------------------------------------------------------------
local function today_titles(spec, root)
  local view_ = view({ source = Source.new({ scope = spec, root = root }) })
  return sorted(titles(view_:_get_agenda_days(), 1))
end
check('current', today_titles('current', alpha), { 'Finished thing', 'Old and unfinished', 'Weekly chore', 'Write report', 'Write report' })
check('tree', today_titles('tree', alpha), { 'Child item', 'Finished thing', 'Old and unfinished', 'Weekly chore', 'Write report', 'Write report' })
check('a list', today_titles({ 'court:beta' }, alpha), { 'Beta item' })
check('court', #today_titles('court', alpha), 7)
tree.write_settings(beta, { merge = false })
check('a hollow that opted out stays out of the court', vim.tbl_contains(today_titles('court', alpha), 'Beta item'), false)
check('but its own agenda has it', today_titles('current', beta), { 'Beta item' })
tree.write_settings(beta, {})

-- a path filter (fey_agenda_files) ----------------------------------------------------------------------
local filtered = view({ source = Source.new({ scope = 'court', paths = { base .. '/beta' } }) })
check('limited to a directory', titles(filtered:_get_agenda_days(), 1), { 'Beta item' })
check('globs', #titles(view({ source = Source.new({ scope = 'court', paths = base .. '/alpha/*.fey' }) }):_get_agenda_days(), 1), 5)

-- filters of the view -------------------------------------------------------------------------------------
check('filter by label', titles(view({ tag_filter = '+home' }):_get_agenda_days(), 1), { 'Child item' })
check('filter by category', #titles(view({ category_filter = 'Work' }):_get_agenda_days(), 1), 5)
check('filter out a label', vim.tbl_contains(titles(view({ tag_filter = '-office' }):_get_agenda_days(), 1), 'Write report'), false)

-- sorting -----------------------------------------------------------------------------------------------
local sorted_view = view({ sorting_strategy = { 'priority-down' } })
check('priority first', titles(sorted_view:_get_agenda_days(), 1)[1], 'Write report')

-- rendering ---------------------------------------------------------------------------------------------
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf)
local rendered = view()
local ok, err = pcall(rendered.render, rendered, buf)
check('renders', { ok, ok and '' or err }, { true, '' })
local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
check('the title', text:find('Week-agenda', 1, true) ~= nil, true)
check('an item line', text:find('Write report', 1, true) ~= nil, true)
check('with its todo keyword and priority', text:find('TODO%s*%[#A%]%s*Write report') ~= nil, true)
check('and its category', text:find('Work:', 1, true) ~= nil, true)
check('the todo of another hollow', text:find('Child item', 1, true) ~= nil, true)
check('lines know their entry', rendered:get_line(4) ~= nil and rendered:get_line(4).heading ~= nil, true)
local out = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
check('the title stays clean', out[1]:match('^Week%-agenda %(W%d+%):$') ~= nil, true)
check('the scope has a line of its own', out[2], 'Scope: court (4 hollows)')
local at
for i, l in ipairs(out) do
  if l:find('Child item', 1, true) then at = i break end
end
check('the item line has no hollow', out[at]:find('court:', 1, true), nil)
check('the hollow is on the line under it', out[at + 1]:find('court:alpha:child · c.fey', 1, true) ~= nil, true)
check('and the line is of the same heading', rendered:get_line(at + 1).heading, rendered:get_line(at).heading)

local function render_with(opts, spec)
  vim.cmd('enew')
  local b = vim.api.nvim_get_current_buf()
  local v2 = view({ source = Source.new({ scope = spec or 'court', root = alpha }) })
  require('fey.config'):extend(opts)
  v2:render(b)
  require('fey.config'):extend({ fey_agenda_show_scope = true, fey_agenda_show_hollow = 'auto' })
  return vim.api.nvim_buf_get_lines(b, 0, -1, false)
end
local function has(lines, text)
  for _, l in ipairs(lines) do
    if l:find(text, 1, true) then return true end
  end
  return false
end
check('never', has(render_with({ fey_agenda_show_hollow = 'never' }), ' · '), false)
check('one hollow needs no line in auto', has(render_with({}, 'current'), ' · '), false)
check('always', has(render_with({ fey_agenda_show_hollow = 'always' }, 'current'), 'court:alpha · a.fey'), true)
check('the scope of one hollow says which', render_with({}, 'current')[2], 'Scope: current (court:alpha)')
check('the scope line can go', render_with({ fey_agenda_show_scope = false })[2]:find('Scope', 1, true), nil)

-- the views that list headings -------------------------------------------------------------------------
local AgendaTypes = require('fey.agenda.types')
local function titles_of(entries)
  local out = vim.tbl_map(function(e) return e:get_title() end, entries)
  table.sort(out)
  return out
end
local function type_view(kind, opts)
  return AgendaTypes[kind]:new(vim.tbl_extend('force', { source = Source.new({ scope = 'court' }), agenda_filter = AgendaFilter:new() }, opts or {}))
end

local headings = Source.new({ scope = 'court' }):headings()
check('every heading is an entry', #headings >= 9, true)
local function entry_of(title)
  for _, e in ipairs(headings) do
    if e:get_title() == title then return e end
  end
end
check('labels of the heading, of its parents and of the document',
  { entry_of('Write report'):get_tags(), entry_of('Nested task'):get_tags(), entry_of('Child item'):get_tags() },
  { { 'office', 'projectx' }, { 'parentlabel' }, { 'home' } })
check('props of a heading', entry_of('Nested task').props.effort, '2')
check('planning dates of an entry', { entry_of('Write report'):get_scheduled_date():is_today(), entry_of('Write report'):get_deadline_date():is_today(), entry_of('Finished thing'):get_closed_date() }, { true, false, nil })
check('the level of a heading', entry_of('Nested task').level, 2)

local todo_view = type_view('todo')
check('todo: the open todo items of every hollow', titles_of(todo_view:get_entries()), { 'Beta item', 'Child item', 'Nested task', 'Old and unfinished', 'Weekly chore', 'Write report' })
check('todo: not the done ones', vim.tbl_contains(titles_of(todo_view:get_entries()), 'Finished thing'), false)
check('todo, current scope', titles_of(type_view('todo', { source = Source.new({ scope = 'current', root = beta }) }):get_entries()), { 'Beta item' })

local function match(q, extra)
  return titles_of(type_view('tags', vim.tbl_extend('force', { match_query = q }, extra or {})):get_entries())
end
check('match: a label', match('home'), { 'Child item' })
check('match: a label of the document', #match('projectx'), 5)
check('match: a label of a parent', match('parentlabel'), { 'Nested task', 'Notes' })
check('match: and, exclude', vim.tbl_contains(match('projectx-office'), 'Write report'), false)
check('match: and, exclude keeps the rest', vim.tbl_contains(match('projectx-office'), 'Weekly chore'), true)
check('match: a quoted label with a dash', match('"big-ish"'), { 'Beta item' })
check('match: unquoted, the dash excludes', vim.tbl_contains(match('big-ish'), 'Beta item'), false)
check('match: a quoted label and a todo keyword', match('"projectx"/TODO'), { 'Old and unfinished', 'Weekly chore', 'Write report' })
check('match: quoted label excluded', vim.tbl_contains(match('"projectx"-"office"'), 'Write report'), false)
check('match: or', match('home|office'), { 'Child item', 'Write report' })
check('match: todo keyword', match('/DONE'), { 'Finished thing' })
check('match: todo keywords and labels', match('projectx/TODO'), { 'Old and unfinished', 'Weekly chore', 'Write report' })
check('match: a string property', match('category="Work"/DONE'), { 'Finished thing' })
check('match: a number property', match('effort>1'), { 'Nested task' })
check('match: priority', match('priority="A"'), { 'Write report' })
check('match: a date property', match('deadline<"<' .. stamp(5) .. '>"'), { 'Beta item', 'Write report' })
check('match: level', match('level=2'), { 'Nested task' })
check('a hollow line for each hollow', type_view('tags_todo', { match_query = 'projectx' }):get_entries()[1].hollow, 'court:alpha')
check('ignore deadlines', vim.tbl_contains(titles_of(type_view('tags', { match_query = 'projectx', todo_ignore_deadlines = 'all' }):get_entries()), 'Write report'), false)
check('ignore scheduled that are past', vim.tbl_contains(titles_of(type_view('tags', { match_query = 'projectx', todo_ignore_scheduled = 'past' }):get_entries()), 'Old and unfinished'), false)

local function search(term)
  return titles_of(type_view('search', { heading_query = term }):get_entries())
end
check('search: in the title', search('report'), { 'Write report' })
check('search: in the text of a heading', search('milk'), { 'Notes' })
check('search: only the text of that heading', search('dairy'), { 'Nested task' })
check('search: case does not matter', search('CHILD'), { 'Child item' })
check('search: plain text, not a pattern', search('(report'), {})

-- rendering the views
local function render_view(kind, opts)
  vim.cmd('enew')
  local b = vim.api.nvim_get_current_buf()
  local v3 = type_view(kind, opts)
  local okr, errr = pcall(v3.render, v3, b)
  return okr and vim.api.nvim_buf_get_lines(b, 0, -1, false) or { tostring(errr) }
end
local todo_lines = render_view('todo')
check('todo view: header, scope, items with a hollow line each', { todo_lines[1], todo_lines[2] }, { 'Global list of TODO items of type: ALL', 'Scope: court (4 hollows)' })
local found
for i, l in ipairs(todo_lines) do
  if l:find('Child item', 1, true) then found = i end
end
check('todo view: the item and its hollow', { todo_lines[found]:find('TODO%s+Child item') ~= nil, todo_lines[found + 1]:find('court:alpha:child · c.fey', 1, true) ~= nil }, { true, true })
check('tags view renders', render_view('tags', { match_query = 'home' })[1], 'Headings with TAGS match: home')
check('search view renders', render_view('search', { heading_query = 'milk' })[1], 'Search words: milk')

-- actions on an item -------------------------------------------------------------------------------------
local Edit = require('fey.agenda.edit')
local function fresh(title)
  local list = Source.new({ scope = 'court' }):headings()
  for _, e in ipairs(list) do
    if e:get_title() == title then return e end
  end
end
local function wait_for(p)
  local done_, value_, err_
  p:next(function(v) done_, value_ = true, v end, function(e) done_, err_ = true, e end)
  vim.wait(3000, function() return done_ end, 10)
  return value_, err_
end
local function action(name, args) return function() return require('fey').action(name, { args = args }) end end

local function nwins() return #vim.api.nvim_list_wins() end
local w0 = nwins()
local before = vim.fn.readfile(alpha .. '/a.fey')
local _, err1 = wait_for(Edit.run(fresh('Write report'), action('fey_mappings.priority_down')))
check('priority action runs', err1, nil)
check('and leaves no window', nwins(), w0)
check('and is written to the file', vim.fn.readfile(alpha .. '/a.fey')[3]:find('status, TODO, B', 1, true) ~= nil, true)
check('and the index knows', fresh('Write report'):get_priority(), 'B')
check('no buffer is left behind', vim.fn.bufnr(alpha .. '/a.fey') == -1 or not vim.api.nvim_buf_is_loaded(vim.fn.bufnr(alpha .. '/a.fey')), true)
check('the rest of the file is as it was', vim.list_slice(vim.fn.readfile(alpha .. '/a.fey'), 4), vim.list_slice(before, 4))

local _, err2 = wait_for(Edit.run(fresh('Weekly chore'), action('fey_mappings.set_tags', { { 'errand', 'weekly' } })))
check('set tags runs', err2, nil)
check('labels changed in the index', fresh('Weekly chore'):get_tags(), { 'errand', 'weekly', 'projectx' })

local _, err3 = wait_for(Edit.run(fresh('Finished thing'), action('fey_mappings.todo_next_state')))
check('todo state runs', err3, nil)
check('the keyword changed', fresh('Finished thing').state ~= 'DONE', true)

-- an unsaved buffer is edited, not written
vim.cmd('edit ' .. vim.fn.fnameescape(beta .. '/b.fey'))
local bbuf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(bbuf, -1, -1, false, { 'unsaved line' })
local disk = vim.fn.readfile(beta .. '/b.fey')
local _, err4 = wait_for(Edit.run(fresh('Beta item'), action('fey_mappings.priority_up')))
check('action on a file with an unsaved buffer', err4, nil)
check('the buffer has the change', vim.api.nvim_buf_get_lines(bbuf, 0, 1, false)[1]:find('status, TODO', 1, true) ~= nil, true)
check('and the unsaved line', vim.api.nvim_buf_get_lines(bbuf, -2, -1, false)[1], 'unsaved line')
check('the disk is untouched', vim.fn.readfile(beta .. '/b.fey'), disk)
check('and the buffer is still modified', vim.bo[bbuf].modified, true)
vim.bo[bbuf].modified = false

local _, err5 = wait_for(Edit.run({ abs = base .. '/nowhere.fey', line = 1 }, function() end))
check('a missing file is an error', type(err5), 'string')

-- the preview lines
check('lines of an entry', fresh('Child item'):get_lines()[1]:find('Child item', 1, true) ~= nil, true)

-- through the agenda window ---------------------------------------------------------------------------
local AG = require('fey.agenda')
local live = AG:new({ source = Source.new({ scope = 'court' }) })
live:open_view('todo')
vim.wait(300)
local function line_of(text)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
    if l:find(text, 1, true) then return i end
  end
end
check('the todo view is open', vim.bo.filetype, 'feyagenda')
vim.api.nvim_win_set_cursor(0, { line_of('Weekly chore'), 0 })
local before_line = vim.api.nvim_buf_get_lines(0, line_of('Weekly chore') - 1, line_of('Weekly chore'), false)[1]
local pv = live:priority_up()
local _, perr = wait_for(pv)
check('the action finished without an error', perr, nil)
vim.wait(1500, function() return vim.api.nvim_buf_get_lines(0, line_of('Weekly chore') - 1, line_of('Weekly chore'), false)[1] ~= before_line end, 20)
local after_line = vim.api.nvim_buf_get_lines(0, line_of('Weekly chore') - 1, line_of('Weekly chore'), false)[1]
check('priority up from the agenda redraws', { before_line:find('[#', 1, true), after_line:find('[#', 1, true) ~= nil }, { nil, true })
check('the window is still the agenda', vim.bo.filetype, 'feyagenda')
check('the file has it', table.concat(vim.fn.readfile(alpha .. '/a.fey'), '\n'):find('Weekly chore') ~= nil, true)

-- the agenda object ---------------------------------------------------------------------------------------
local A = require('fey.agenda')
local agenda = A:new({ source = Source.new({ scope = 'court' }) })
check('the agenda has a source', agenda.source ~= nil, true)
check('and the default scope is the court', Source.new():get_scope(), 'court')

-- the mappings that work outside of a document ---------------------------------------------------------
vim.cmd('enew')
vim.bo.filetype = 'text'
local conf = require('fey.config')
conf:extend({ mappings = { prefix = '<Space>' } })
conf:setup_mappings('global')
for key, lhs in pairs({ fey_agenda = 'a', fey_hollow_init = 'vi', fey_vault_reindex = 'vr', fey_hollow_jump = 'vj', fey_hollow_jump_tab = 'vJ', fey_db_new = 'bn', fey_db_pick = 'bl' }) do
  check('global mapping ' .. key, vim.fn.maparg('<Space>' .. lhs, 'n') ~= '', true)
end
conf:setup_mappings('global')
check('and not only in a buffer', vim.fn.maparg('<Space>vi', 'n', false, true).buffer, 0)

-- a leftover fey_agenda_files does not filter the agenda
conf:extend({ fey_agenda_files = base .. '/nowhere/**/*' })
check('fey_agenda_files is not a filter', Source.new().paths, nil)

-- the agenda buffer: mappings, help, goto --------------------------------------------------------------
local abuf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(abuf)
conf:setup_mappings('agenda', abuf)
for _, lhs in ipairs({ 'f', 'b', '.', 'vd', 'vw', 'vm', 'vy', 'q', '<CR>', '<Tab>', 'J', 'r', '/', 'g?', 't', '+', '-', '<Space>,', '<Space>t', '<Space>id', '<Space>is', '<Space>A', 'K' }) do
  check('agenda mapping ' .. lhs, vim.fn.maparg(lhs, 'n', false, true).buffer, 1)
end
local help = require('fey.objects.help')
local lines_ = help.prepare_content('agenda')
local text_ = table.concat(lines_, '\n')
check('the help lists the agenda mappings', { text_:find('Close agenda', 1, true) ~= nil, text_:find('Show week view', 1, true) ~= nil, text_:find('Show this help', 1, true) ~= nil }, { true, true, true })
local entry_ = by_title['Write report']
vim.cmd('enew')
require('fey.utils').goto_heading(entry_)
check('goto opens the file of the entry', vim.api.nvim_buf_get_name(0), alpha .. '/a.fey')
check('on its line', vim.fn.line('.'), 3)

if failures > 0 then
  print(('%d of %d checks failed'):format(failures, total))
  vim.cmd('cquit 1')
end
print(('ok: %d checks'):format(total))
vim.cmd('qa!')
