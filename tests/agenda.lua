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
  '',
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
write(child .. '/c.fey', { '  I. {# status, TODO #} Child item {# labels, home #}', '{# scheduled, ' .. stamp(0) .. ' #}', '' })
write(beta .. '/.fey/x', {})
write(beta .. '/b.fey', { '  I. {# status, TODO #} Beta item', '{# deadline, ' .. stamp(0) .. ' #}', '' })
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
check('labels are the tags', report:get_tags(), { 'office' })
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

if failures > 0 then
  print(('%d of %d checks failed'):format(failures, total))
  vim.cmd('cquit 1')
end
print(('ok: %d checks'):format(total))
vim.cmd('qa!')
