-- Dates, tasks and heading properties in the vault index. Run from the repo root:
--
--   FEY_PARSER=/path/to/fey.so nvim --headless -u NONE -l tests/index.lua
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

local function ts(s) return os.time({ year = tonumber(s:sub(1, 4)), month = tonumber(s:sub(6, 7)), day = tonumber(s:sub(9, 10)), hour = tonumber(s:sub(12, 13)) or 0, min = tonumber(s:sub(15, 16)) or 0 }) end

-- extraction ------------------------------------------------------------------------
local extract = require('fey.vault.extract')
local meta = extract.extract(table.concat({
  '{# table; title: T #}',
  '',
  '  I. {# status, TODO, A #} Write the report {# labels, work #}',
  '{# scheduled, 2026-10-06 Tue 10:00-11:00 +1w #} {# deadline, 2026-10-10 Sat; warn: 3d #}',
  '{# prop; effort: 2h; category: work #}',
  '',
  'A meeting on {@ date, 2026-10-08 Thu 14:00 @} and {@ date, 2026-10-12 Mon--2026-10-14 Wed; active: false @}.',
  '',
  '  I.A. {# status, DONE #} Done child',
  '{# closed, 2026-10-01 Thu #}',
  '',
  '  I.B. {# status; priority: B #} Only a priority',
  '',
  '  I.C. Plain',
  '{# status, TODO #} not the first thing of the title: text',
  '',
}, '\n'))

check('no errors', meta.errors, {})
check('tasks', vim.tbl_map(function(t) return { t.heading_ord, t.state, t.done, t.priority, t.title } end, meta.tasks), {
  { 1, 'TODO', false, 'A', 'Write the report' },
  { 2, 'DONE', true, nil, 'Done child' },
  { 3, nil, false, 'B', 'Only a priority' },
})
check('heading props', { meta.headings[1].props, meta.headings[2].props }, { { effort = '2h', category = 'work' }, {} })

local by_kind = {}
for _, d in ipairs(meta.dates) do
  by_kind[#by_kind + 1] = { d.kind, d.heading_ord, d.active, d.start_time, d.repeater, d.warn }
end
check('dates', by_kind, {
  { 'scheduled', 1, true, true, '+1w', nil },
  { 'deadline', 1, true, false, nil, '-3d' },
  { 'date', 1, true, true, nil, nil },
  { 'date', 1, false, false, nil, nil },
  { 'closed', 2, false, false, nil, nil },
})
check('date times', { meta.dates[1].start_ts, meta.dates[1].end_ts, meta.dates[1].end_time }, { ts('2026-10-06 10:00'), ts('2026-10-06 11:00'), true })
check('date range', { meta.dates[4].start_ts, meta.dates[4].end_ts }, { ts('2026-10-12'), ts('2026-10-14') })
check('a file keyword list', #extract.extract('{# table; todo: A B | C #}\n\n  I. {# status, C #} x\n', {
  todo_lookup = function(todo)
    local out = {}
    for i, k in ipairs(vim.split(todo, '%s+')) do
      if k ~= '|' then out[k] = { type = (k == 'C') and 'DONE' or 'TODO' } end
    end
    return out
  end,
}).tasks, 1)

-- the index --------------------------------------------------------------------------
local root = vim.fn.tempname()
vim.fn.mkdir(root .. '/.fey', 'p')
vim.fn.writefile({
  '  I. {# status, TODO, A #} One {# labels, work #}',
  '{# scheduled, 2026-10-06 Tue 10:00 #}',
  '{# prop; effort: 2h #}',
  '',
  '  I.A. {# status, DONE #} Two',
  '{# deadline, 2026-10-07 Wed #}',
  '',
}, root .. '/a.fey')
vim.fn.writefile({ '  I. {# status, TODO #} Three', '{# deadline, 2026-11-01 Sun #} {# date, 2026-10-30 Fri #}', '' }, root .. '/b.fey')

require('fey.vault').attach(root, {})
local api = require('fey.api')
local vault = api.current_vault()
check('ready', vault:wait(), true)
local v = vault._vault

local function paths(rows) return vim.tbl_map(function(r) return r.path .. ':' .. (r.kind or '') end, rows) end
check('all dates', paths(v:dates()), { 'a.fey:scheduled', 'a.fey:deadline', 'b.fey:date', 'b.fey:deadline' })
check('dates of a kind', paths(v:dates({ kinds = { 'deadline' } })), { 'a.fey:deadline', 'b.fey:deadline' })
check('dates in a range', paths(v:dates({ from = ts('2026-10-06'), to = ts('2026-10-08') })), { 'a.fey:scheduled', 'a.fey:deadline' })
check('open dates only', paths(v:dates({ open_only = true })), { 'a.fey:scheduled', 'b.fey:date', 'b.fey:deadline' })
check('dates of a file', #v:dates({ path = 'b.fey' }), 2)
local first = v:dates()[1]
check('a date knows its heading and task', { first.heading_title, first.signature, first.state, first.done, first.priority }, { 'One', 'I.', 'TODO', 0, 'A' })

local tasks = v:tasks()
check('tasks', vim.tbl_map(function(t) return { t.path, t.title, t.state, t.done, t.priority } end, tasks), {
  { 'a.fey', 'One', 'TODO', false, 'A' },
  { 'a.fey', 'Two', 'DONE', true, nil },
  { 'b.fey', 'Three', 'TODO', false, nil },
})
check('task labels', tasks[1].labels, { 'work' })
check('open tasks', #v:tasks({ done = false }), 2)
check('tasks by state', #v:tasks({ state = 'DONE' }), 1)
check('tasks by priority', #v:tasks({ priority = 'A' }), 1)
check('tasks by label', #v:tasks({ label = 'work' }), 1)
check('heading props in the index', v:headings('a.fey')[1].props, '{"effort":"2h"}')

-- the query language ---------------------------------------------------------------------
local function items(src)
  local result = vault:run_query(src)
  return vim.tbl_map(function(item)
    local t = item.task
    return t and (t.state ~= vim.NIL and t.state or '-') .. ':' .. t.text or tostring(item.id)
  end, result.items or {})
end
check('TASK', items('TASK'), { 'TODO:One', 'DONE:Two', 'TODO:Three' })
check('TASK without done ones', items('TASK WHERE !completed'), { 'TODO:One', 'TODO:Three' })
check('TASK from a file', items('TASK FROM "b.fey"'), { 'TODO:Three' })
check('TASK by label', items('TASK FROM #work'), { 'TODO:One', 'DONE:Two' })
check('TASK by priority', items('TASK WHERE priority = "A"'), { 'TODO:One' })
check('TASK with a date', items('TASK WHERE deadline AND deadline < date(2026-10-20)'), { 'DONE:Two' })
check('TASK sorted', items('TASK SORT text DESC'), { 'DONE:Two', 'TODO:Three', 'TODO:One' })
check('TASK limited', #items('TASK LIMIT 2'), 2)
check('tasks of a page', vault:run_query('TABLE length(file.tasks) AS n FROM "a.fey"').rows[1][2], 2)
check('scheduled of a task', vault:run_query('TABLE rows.scheduled FROM "a.fey" FLATTEN file.tasks AS rows').count, 2)
local rendered = require('fey.query.render').lines(vault:run_query('TASK FROM "a.fey" WHERE !completed'))
check('rendered task', rendered, { '-  TODO {@ link, a.fey; desc: One; section: I. @} (A)' })
check('grouped tasks', #vault:run_query('TASK GROUP BY state').items, 2)

-- text that is not saved ----------------------------------------------------------------
local revision = v.revision
check('index_text', v:index_text(root .. '/b.fey', { '  I. {# status, DONE #} Three', '{# deadline, 2026-11-02 Mon #}', '' }), true)
check('revision moves', v.revision > revision, true)
check('the text is indexed', { v:tasks({ path = 'b.fey' })[1].state, v:dates({ path = 'b.fey' })[1].kind }, { 'DONE', 'deadline' })
v:scan({}, function() end)
vim.wait(500, function() return v.state == 'ready' end, 20)
check('a scan keeps it', v:tasks({ path = 'b.fey' })[1].state, 'DONE')
check('saving replaces it', (function() vim.fn.writefile({ '  I. {# status, TODO #} Three' }, root .. '/b.fey'); v:index_path(root .. '/b.fey'); return v:tasks({ path = 'b.fey' })[1].state end)(), 'TODO')
check('a file that is not on the disk is not indexed', v:index_text(root .. '/new.fey', { '  I. x' }), false)
check('a path outside is not indexed', v:index_text('/tmp/outside.fey', { '  I. x' }), false)

if failures > 0 then
  print(('%d of %d checks failed'):format(failures, total))
  vim.cmd('cquit 1')
end
print(('ok: %d checks'):format(total))
vim.cmd('qa!')
