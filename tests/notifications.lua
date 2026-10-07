-- Reminders read from the index. Run from the repo root:
--
--   FEY_PARSER=/path/to/fey.so nvim --headless --clean -l tests/notifications.lua
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

local tree = require('fey.hollow.tree')
local court = require('fey.hollow.court')
local registry = require('fey.vault')
local Date = require('fey.objects.date')
local Notifications = require('fey.notifications')

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

court.ensure_dirs()
local now = Date.now()
local soon = now:add({ min = 10 })
local yesterday_soon = soon:add({ day = -1 })
local alpha, beta = base .. '/alpha', base .. '/beta'
write(alpha .. '/.fey/x', {})
write(beta .. '/.fey/x', {})
write(alpha .. '/a.fey', {
  '{# table; category: Work #}',
  '',
  '  I. {# status, TODO, A #} Scheduled soon',
  '{# scheduled, ' .. soon:to_tag_value() .. ' #}',
  '',
  '  II. {# status, TODO #} Deadline soon',
  '{# deadline, ' .. soon:to_tag_value() .. ' #}',
  '',
  '  III. {# status, DONE #} Finished',
  '{# scheduled, ' .. soon:to_tag_value() .. ' #}',
  '',
  '  IV. {# status, TODO #} Later',
  '{# scheduled, ' .. now:add({ min = 90 }):to_tag_value() .. ' #}',
  '',
  '  V. {# status, TODO #} Every day',
  '{# scheduled, ' .. yesterday_soon:to_tag_value() .. ' +1d #}',
  '',
  '  VI. {# status, TODO #} Past',
  '{# scheduled, ' .. now:add({ day = -3 }):to_tag_value() .. ' #}',
  '',
})
write(beta .. '/b.fey', { '  I. {# status, TODO #} In another hollow', '{# scheduled, ' .. soon:to_tag_value() .. ' #}', '' })
write(alpha .. '/a.fey_archive', { '  I. {# status, TODO #} Archived', '{# scheduled, ' .. soon:to_tag_value() .. ' #}', '' })
for _, root in ipairs({ alpha, beta }) do
  tree.register_chain(root)
  scan(root)
end

local function titles(tasks)
  local out = vim.tbl_map(function(t) return t.title .. ':' .. t.type .. ':' .. t.reminder_type end, tasks)
  table.sort(out)
  return out
end
local notifications = Notifications:new()

-- the defaults: a reminder 10 minutes before
conf:extend({ notifications = { reminder_time = 10, deadline_reminder = true, scheduled_reminder = true, repeater_reminder_time = false, deadline_warning_reminder_time = false } })
local tasks = notifications:get_tasks(now)
check('reminders ten minutes ahead, in every hollow', titles(tasks), {
  'Deadline soon:DEADLINE:time',
  'In another hollow:SCHEDULED:time',
  'Scheduled soon:SCHEDULED:time',
})
check('a done item is not reminded', #vim.tbl_filter(function(t) return t.title == 'Finished' end, tasks), 0)
check('nor an archived one', #vim.tbl_filter(function(t) return t.title == 'Archived' end, tasks), 0)
local first
for _, t in ipairs(tasks) do
  if t.title == 'Scheduled soon' then first = t end
end
check('a reminder says what it is about', {
  first.todo, first.priority, first.category, first.signature, first.hollow, first.minutes, first.humanized_duration ~= nil,
}, { 'TODO', 'A', 'Work', 'I.', 'court:alpha', 10, true })
check('and where', { first.file, first.line }, { alpha .. '/a.fey', 3 })

-- kinds can be switched off
conf:extend({ notifications = { deadline_reminder = false } })
check('no deadline reminders', #vim.tbl_filter(function(t) return t.type == 'DEADLINE' end, notifications:get_tasks(now)), 0)
conf:extend({ notifications = { deadline_reminder = true, scheduled_reminder = false } })
check('no scheduled reminders', #vim.tbl_filter(function(t) return t.type == 'SCHEDULED' end, notifications:get_tasks(now)), 0)
conf:extend({ notifications = { scheduled_reminder = true } })

-- a repeater
conf:extend({ notifications = { repeater_reminder_time = 10, reminder_time = false } })
local repeats = notifications:get_tasks(now)
check('a repeating date reminds before its next time', titles(repeats), { 'Every day:SCHEDULED:repeater' })
conf:extend({ notifications = { repeater_reminder_time = false, reminder_time = 10 } })

-- another time
check('nothing at another time', #notifications:get_tasks(now:add({ min = 30 })), 0)
check('the later item at its time', titles(notifications:get_tasks(now:add({ min = 80 }))), { 'Later:SCHEDULED:time' })

-- scope
conf:extend({ notifications = { scope = { 'court:beta' } } })
check('a scope limits the reminders', titles(Notifications:new():get_tasks(now)), { 'In another hollow:SCHEDULED:time' })
conf:extend({ notifications = { scope = nil } })

-- the popup text and the custom notifier
local seen
conf:extend({ notifications = { notifier = function(list) seen = list end } })
notifications:notify(now)
check('a custom notifier gets the tasks', #seen, 3)
conf:extend({ notifications = { notifier = nil } })

-- no files are loaded
check('the reminders need no loaded files', require('fey').instance and true, true)
check('the timer start returns the object', (function()
  local n = Notifications:new()
  local r = n:start_timer()
  n:stop_timer()
  return r == n
end)(), true)

if failures > 0 then
  print(('%d of %d checks failed'):format(failures, total))
  vim.cmd('cquit 1')
end
print(('ok: %d checks'):format(total))
vim.cmd('qa!')
