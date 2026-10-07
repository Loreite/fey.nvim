-- Settings written in the notes: the cascade, the limits, hot loading. Run from the repo root:
--
--   FEY_PARSER=/path/to/fey.so nvim --headless --clean -l tests/settings.lua
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
local Options = require('fey.settings.options')
local Layers = require('fey.settings.layers')
local settings = require('fey.settings')

local function write(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  vim.fn.writefile(lines, path)
end
local function open(path)
  vim.cmd('edit! ' .. vim.fn.fnameescape(path))
  vim.bo.filetype = 'fey'
end

-- the policy ------------------------------------------------------------------------------------------------------
check('a local option is fine', { Options.check('tabstop') }, { true, nil, { name = 'tabstop', scope = 'buf', type = 'number' } })
check('a window option is fine', (select(3, Options.check('wrap'))).scope, 'win')
check('the two global ones', { (Options.check('colorscheme')), (Options.check('background')) }, { true, true })
check('a global option is not', { Options.check('laststatus') }, { false, 'a global option' })
check('an expression is denied', (select(2, Options.check('indentexpr'))):find('denied', 1, true) ~= nil, true)
for _, name in ipairs({ 'foldexpr', 'formatexpr', 'omnifunc', 'completefunc', 'formatprg', 'makeprg', 'keywordprg', 'equalprg', 'statusline', 'includeexpr', 'tagfunc', 'modeline', 'exrc' }) do
  check(name .. ' is denied', (Options.check(name)), false)
end
check('unless it is allowed by name', (Options.check('foldexpr', { 'foldexpr' })), true)
check('allowed as a map too', (Options.check('foldexpr', { foldexpr = true })), true)
check('something else allowed does not open it', (Options.check('indentexpr', { 'foldexpr' })), false)
check('not an option', { Options.check('nonsense') }, { false, 'not an option' })
check('a name with odd characters is not looked up', { Options.check('tab stop | echo') }, { false, 'not an option' })
local ts_info = select(3, Options.check('tabstop'))
check('values are coerced', { Options.coerce(ts_info, '4'), Options.coerce(select(3, Options.check('wrap')), 'false'), Options.coerce(select(3, Options.check('wrap')), 'maybe'), Options.coerce(select(3, Options.check('formatoptions')), { 'a', 'b' }) }, { 4, false, nil, 'a,b' })

-- reading tags ----------------------------------------------------------------------------------------------------
local layer = Layers.read(table.concat({
  '{# nvim; tabstop: 4; wrap: false; colorscheme: desert #}',
  '{# plugin, fey; fey_conceal_task_tags: false; fey_deadline_warning_days: 3 #}',
  '[ plugin, fey #]',
  'fey_checkbox_icons_:  nerd',
  'notifications_:',
  '    reminder_time_:  5',
  'fey_todo_keywords_:',
  '    -  TODO',
  '    -  DONE',
  '[# plugin ]',
  '{# plugin, other; a: 1 #}',
  '',
}, '\n'), 'text')
check('nvim keys, with their values read as Lua', layer.nvim, { tabstop = 4, wrap = false, colorscheme = 'desert' })
local plugin_names = vim.tbl_keys(layer.plugins)
table.sort(plugin_names)
check('plugin tags, by the first value', plugin_names, { 'fey', 'other' })
check('keys of a plugin tag', { layer.plugins.fey.fey_conceal_task_tags, layer.plugins.fey.fey_deadline_warning_days }, { false, 3 })
check('the body of a pair tag is read like a table tag', { layer.plugins.fey.fey_checkbox_icons, layer.plugins.fey.notifications, layer.plugins.fey.fey_todo_keywords }, { 'nerd', { reminder_time = 5 }, { 'TODO', 'DONE' } })
check('another plugin', layer.plugins.other, { a = 1 })
check('a block tag has a body too', (Layers.read('[ nvim ]#\n    tabstop_:  3\n', 'x') or {}).nvim, { tabstop = 3 })
check('a text that does not parse is nil', Layers.read('{# nvim; ; ; #}\n', 'x'), nil)
check('no tags, an empty layer', (Layers.read('  I. Nothing\n', 'x')).nvim, {})
check('values', { Layers.coerce('true'), Layers.coerce('12'), Layers.coerce('1.5'), Layers.coerce('x12'), Layers.coerce('007') }, { true, 12, 1.5, 'x12', 7 })

-- a court, a hollow in a hollow, a file --------------------------------------------------------------------------------
local court_dir = court.ensure_dirs()
local outer, inner = base .. '/outer', base .. '/outer/inner'
write(outer .. '/.fey/x', {})
write(inner .. '/.fey/x', {})
tree.register_chain(outer)
tree.register_chain(inner)
vim.fn.delete(outer .. '/.fey/x')
vim.fn.delete(inner .. '/.fey/x')
write(court_dir .. '/.fey/config.fey', { '{# nvim; colorscheme: default; shiftwidth: 2; tabstop: 2 #}', '{# plugin, fey; fey_deadline_warning_days: 30; fey_conceal_task_tags: false #}', '' })
write(outer .. '/.fey/config.fey', { '{# nvim; shiftwidth: 3 #}', '{# plugin, fey; fey_deadline_warning_days: 20 #}', '' })
write(inner .. '/.fey/config.fey', { '{# nvim; background: light #}', '' })
local note = inner .. '/note.fey'
write(note, { '  I. A note', '' })

check('the config files of a note, widest first', vim.tbl_map(function(p) return p:sub(#base + 1) end, settings.config_files(note)), {
  '/court/.fey/config.fey', '/outer/.fey/config.fey', '/outer/inner/.fey/config.fey',
})
conf:extend({ settings = { cascade = false } })
check('without the cascade only the court', #settings.config_files(note), 1)
conf:extend({ settings = { cascade = true } })

open(note)
local before_scheme = vim.g.colors_name
local before_bg = vim.o.background
local eff = settings.effective(vim.api.nvim_get_current_buf())
check('the layers merge: later wins, key by key', { eff.nvim.colorscheme, eff.nvim.shiftwidth, eff.nvim.tabstop, eff.nvim.background }, { 'default', 3, 2, 'light' })
check('and the plugin options', { eff.plugins.fey.fey_deadline_warning_days, eff.plugins.fey.fey_conceal_task_tags }, { 20, false })
check('each setting knows where it came from', { eff.from.shiftwidth:sub(#base + 1), eff.from.tabstop:sub(#base + 1) }, { '/outer/.fey/config.fey', '/court/.fey/config.fey' })

-- applying: once, from the merged table ----------------------------------------------------------------------------------
local schemes = 0
vim.api.nvim_create_autocmd('ColorScheme', { callback = function() schemes = schemes + 1 end })
local warn_before = conf.fey_deadline_warning_days
local conceal_before = conf.fey_conceal_task_tags
settings.apply()
check('the colour scheme of the court is applied once', { vim.g.colors_name, schemes }, { 'default', 1 })
check('the nearest value of a local option wins', { vim.bo.shiftwidth, vim.bo.tabstop }, { 3, 2 })
check('a global option of a hollow', vim.o.background, 'light')
check('the options of the plugin', { conf.fey_deadline_warning_days, conf.fey_conceal_task_tags }, { 20, false })
settings.apply()
check('applying again changes nothing', schemes, 1)

-- the note's own tags win, and give way when removed ---------------------------------------------------------------------
vim.api.nvim_buf_set_lines(0, 0, 0, false, { '{# nvim; shiftwidth: 8; colorscheme: habamax; wrap: false #}', '{# plugin, fey; fey_deadline_warning_days: 5 #}' })
settings.apply()
check('the note beats the hollow and the court', { vim.bo.shiftwidth, vim.g.colors_name, conf.fey_deadline_warning_days }, { 8, 'habamax', 5 })
check('a window option', vim.wo.wrap, false)
vim.api.nvim_buf_set_lines(0, 0, 2, false, {})
settings.apply()
check('without the tags it is the hollow again', { vim.bo.shiftwidth, vim.g.colors_name, conf.fey_deadline_warning_days }, { 3, 'default', 20 })
check('a window option goes back', vim.wo.wrap, true)

-- what a note may not do ------------------------------------------------------------------------------------------------
vim.g.fey_test_marker = 'untouched'
vim.api.nvim_buf_set_lines(0, 0, 0, false, {
  '{# nvim; indentexpr: v:lua.vim.g.fey_pwned(); formatprg: touch /tmp/pwned; laststatus: 0; nonsense: 1; tabstop: 6 #}',
  '{# plugin, fey; fey_court_dir: /tmp/elsewhere; mappings: x; fey_deadline_warning_days: 7 #}',
  '{# plugin, nothere; a: 1 #}',
})
settings.apply()
check('an allowed option next to denied ones is applied', vim.bo.tabstop, 6)
check('an expression is not set', vim.bo.indentexpr == '' or not vim.bo.indentexpr:find('pwned', 1, true), true)
check('a program is not set', vim.bo.formatprg, '')
check('a global option is not set', vim.o.laststatus ~= 0 or vim.o.laststatus == 0 and false, true)
check('where things live cannot be changed', conf.fey_court_dir, base .. '/court')
check('an option of the plugin that is allowed is applied', conf.fey_deadline_warning_days, 7)
local report = table.concat(settings.report(), '\n')
check('the report says what was ignored and why', { report:find('indentexpr: indentexpr is an expression: denied', 1, true) ~= nil, report:find('laststatus: a global option', 1, true) ~= nil, report:find('nonsense: not an option', 1, true) ~= nil, report:find('fey.fey_court_dir: not an option a note may change', 1, true) ~= nil, report:find('plugin nothere: not a registered plugin', 1, true) ~= nil }, { true, true, true, true, true })
check('and where settings come from', report:find('/outer/.fey/config.fey', 1, true) ~= nil, true)
-- allowed by name
conf:extend({ settings = { allow = { 'foldexpr' } } })
vim.api.nvim_buf_set_lines(0, 0, 3, false, { '{# nvim; foldmethod: expr; foldexpr: 0 #}' })
settings.apply()
check('an unsafe option the user allowed is set', vim.wo.foldexpr, '0')
conf:extend({ settings = { allow = {} } })
vim.api.nvim_buf_set_lines(0, 0, 1, false, {})
settings.apply()

-- a colour scheme name is a plain name -----------------------------------------------------------------------------------
vim.api.nvim_buf_set_lines(0, 0, 0, false, { '{# nvim; colorscheme: default | let g:fey_test_marker = "pwned" #}' })
settings.apply()
check('a colour scheme name with a command in it is refused', { vim.g.fey_test_marker, vim.g.colors_name }, { 'untouched', 'default' })
vim.api.nvim_buf_set_lines(0, 0, 1, false, { '{# nvim; colorscheme: nosuchscheme #}' })
settings.apply()
check('a colour scheme that does not exist is ignored', vim.g.colors_name, 'default')
vim.api.nvim_buf_set_lines(0, 0, 1, false, {})

-- hooks: off unless named --------------------------------------------------------------------------------------------------
vim.g.fey_hook_ran = nil
vim.api.nvim_buf_set_lines(0, 0, 0, false, { '{# nvim; buf_enter: let g:fey_hook_ran = "yes"; wrap: false #}' })
settings.apply()
settings.run_hooks(vim.api.nvim_get_current_buf())
check('without names the commands do not run', vim.g.fey_hook_ran, nil)
check('and the key is not an option', settings.state.bufs[vim.api.nvim_get_current_buf()].applied.buf_enter, nil)
conf:extend({ settings = { hooks = { buf_enter = 'buf_enter', buf_leave = 'buf_leave' } } })
settings.apply()
settings.run_hooks(vim.api.nvim_get_current_buf())
check('with the key named, the command runs', vim.g.fey_hook_ran, 'yes')
vim.g.fey_hook_ran = nil
settings.run_hooks(vim.api.nvim_get_current_buf(), 'buf_leave')
check('only the hook that was asked for', vim.g.fey_hook_ran, nil)
conf:extend({ settings = { hooks = {} } })
vim.api.nvim_buf_set_lines(0, 0, 1, false, {})
settings.apply()

-- other plugins: registered, with data from the note --------------------------------------------------------------------
local applied_with, restored = {}, 0
settings.register('demo', { apply = function(opts) applied_with[#applied_with + 1] = vim.deepcopy(opts) end, restore = function() restored = restored + 1 end })
vim.api.nvim_buf_set_lines(0, 0, 0, false, { '{# plugin, demo; theme: dark; size: 3 #}' })
settings.apply()
settings.apply()
check('a registered plugin gets the options once', applied_with, { { theme = 'dark', size = 3 } })
vim.api.nvim_buf_set_lines(0, 0, 1, false, { '{# plugin, demo; theme: light #}' })
settings.apply()
check('and again when they change', applied_with[2], { theme = 'light' })
vim.api.nvim_buf_set_lines(0, 0, 1, false, {})
settings.apply()
check('restore runs when no note asks any more', restored, 1)
conf:extend({ settings = { plugins = { fromconfig = function(opts) applied_with[#applied_with + 1] = opts end } } })
vim.api.nvim_buf_set_lines(0, 0, 0, false, { '{# plugin, fromconfig; x: 1 #}' })
settings.apply()
check('a handler in the setup works too', applied_with[#applied_with], { x = 1 })
conf:extend({ settings = { plugins = {} } })
vim.api.nvim_buf_set_lines(0, 0, 1, false, {})

-- a config file edited in a buffer counts at once -------------------------------------------------------------------------
local hollow_cfg = outer .. '/.fey/config.fey'
vim.cmd('edit! ' .. vim.fn.fnameescape(hollow_cfg))
vim.bo.filetype = 'fey'
vim.api.nvim_buf_set_lines(0, 0, 1, false, { '{# nvim; shiftwidth: 5 #}' })
open(note)
settings.apply()
check('an unsaved edit of a config file applies', vim.bo.shiftwidth, 5)
vim.cmd('bwipeout! ' .. vim.fn.bufnr(hollow_cfg))
settings.apply()
check('and the file on the disk when the buffer is gone', vim.bo.shiftwidth, 3)

-- a parse error in the note changes nothing --------------------------------------------------------------------------------
vim.api.nvim_buf_set_lines(0, 0, 0, false, { '{# nvim; ; ; #}' })
check('a note that does not parse', settings.apply(), nil)
check('is left as it was', vim.bo.tabstop, 2)
vim.api.nvim_buf_set_lines(0, 0, 1, false, {})

-- triggers and mappings ---------------------------------------------------------------------------------------------------
settings.setup()
local events = {}
for _, a in ipairs(vim.api.nvim_get_autocmds({ group = 'FeySettings' })) do
  events[a.event] = true
end
check('the autocommands', { events.FileType, events.BufEnter, events.BufWinEnter, events.BufLeave, events.TextChanged, events.InsertLeave, events.BufWritePost }, { true, true, true, true, true, true, true })
check('the command', vim.fn.exists(':FeySettings'), 2)
check('apply at enter can be toggled', { settings.toggle_apply_at_enter(), settings.toggle_apply_at_enter() }, { false, true })
check('so can the buffer commands', { settings.toggle_hooks_at_enter(), settings.toggle_hooks_at_enter() }, { false, true })

conf:extend({ mappings = { prefix = '<Space>' } })
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf)
conf:setup_mappings('fey', buf)
for _, lhs in ipairs({ '<Space>?a', '<Space>?t', '<Space>?e', '<Space>!a', '<Space>!t', '<Space>!e' }) do
  check('mapping ' .. lhs, vim.fn.maparg(lhs, 'n', false, true).buffer, 1)
end

-- the tag at the cursor is applied on top ---------------------------------------------------------------------------------
open(note)
settings.apply()
vim.api.nvim_buf_set_lines(0, 0, 0, false, { '{# nvim; tabstop: 7 #}', '{# nvim; shiftwidth: 7 #}' })
vim.api.nvim_win_set_cursor(0, { 2, 3 })
settings.apply_tag_at_cursor()
check('just the tag under the cursor is applied', { vim.bo.shiftwidth, vim.bo.tabstop }, { 7, 2 })
check('and does not undo what was applied', vim.o.background, 'light')

if failures > 0 then
  print(('%d of %d checks failed'):format(failures, total))
  vim.cmd('cquit 1')
end
print(('ok: %d checks'):format(total))
vim.cmd('qa!')
