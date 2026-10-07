-- The checks of the setup: the options, `:checkhealth`, the toggles, the help windows and the mappings that were switched on. Run from the repo root:
--
--   FEY_PARSER=/path/to/fey.so nvim --headless --clean -l tests/health.lua
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
  vim.fn.mkdir(d .. '/.fey', 'p')
  return d
end)())
local validate = require('fey.config.validate')
local config = require('fey.config')

-- the options ---------------------------------------------------------------------------------------------------
local function messages(opts)
  return vim.tbl_map(function(p) return p.name end, validate.check(opts, require('fey.config.defaults')))
end
check('good options are fine', messages({ fey_drawer_form = 'block', fey_highlight_overdue = false, fey_math_tag_name = 'tex', win_border = 'single' }), {})
check('options with no default are known', messages({ fey_id_prefix = 'x' }), {})
check('a name that is not an option', messages({ fey_tpyo = 1 }), { 'fey_tpyo' })
check('removed options say so', messages({ fey_use_cwd_config = true, emacs_config = {}, hyperlinks = { sources = {} } }), { 'emacs_config', 'fey_use_cwd_config', 'hyperlinks' })
check('a boolean has to be one', messages({ fey_highlight_overdue = 'yes' }), { 'fey_highlight_overdue' })
check('a tag name has to be a string', messages({ fey_comment_tag_name = 3 }), { 'fey_comment_tag_name' })
check('a choice has to be one of them', messages({ fey_checkbox_icons = 'big', fey_startup_folded = 'overview' }), { 'fey_checkbox_icons' })
check('nothing of the removed ones is in the defaults', { config.fey_use_cwd_config, config.fey_tags_column, config.fey_agenda_text_search_extra_files }, {})

-- setup says it, and uses the options all the same
local warned = {}
local notify = vim.notify
vim.notify = function(msg) warned[#warned + 1] = msg end
require('fey').setup({ fey_court_dir = base .. '/court', fey_tpyo = 1, fey_math_tag_name = 'tex' })
vim.notify = notify
check('setup warns', warned, { 'fey: `fey_tpyo` is not an option' })
check('and goes on', config.fey_math_tag_name, 'tex')
config:extend({ fey_math_tag_name = 'math' })
check('the options of setup are kept for the health check', require('fey').setup_options().fey_tpyo, 1)

-- vault status and :checkhealth ---------------------------------------------------------------------------------------
vim.fn.writefile({ '  I. A', '', '{# weird, x #} {# status, TODO #}' }, base .. '/a.fey')
local vault = require('fey.vault').open(base)
local done = false
vault:scan({}, function() done = true end)
vim.wait(5000, function() return done end, 10)
local s = vault:status()
check('a fresh index', { s.files, s.db_schema == s.schema, #s.changed, #s.new, #s.removed, #s.errors }, { 1, true, 0, 0, 0, 0 })
vim.uv.sleep(20)
vim.fn.writefile({ '  I. A', '', 'changed' }, base .. '/a.fey')
vim.fn.writefile({ '  I. New' }, base .. '/new.fey')
s = vault:status()
check('changed and new files are stale', { s.changed, s.new }, { { 'a.fey' }, { 'new.fey' } })
vim.fn.delete(base .. '/a.fey')
check('a deleted file', vault:status().removed, { 'a.fey' })
vim.fn.writefile({ '  I. A', '', '{# weird, x #} {# status, TODO #}' }, base .. '/a.fey')
done = false
vault:scan({}, function() done = true end)
vim.wait(5000, function() return done end, 10)

local report = {}
for _, fn in ipairs({ 'start', 'ok', 'warn', 'error', 'info' }) do
  vim.health[fn] = function(msg, advice)
    report[#report + 1] = { fn, msg, advice }
  end
end
local function said(kind, pattern)
  for _, r in ipairs(report) do
    if r[1] == kind and r[2]:find(pattern) then return true end
  end
  return false
end
vim.cmd('edit ' .. vim.fn.fnameescape(base .. '/a.fey'))
require('fey.health').check_options()
check('health: the options are reported', said('warn', '1 problem with the options'), true)
require('fey.health').check_vaults()
check('health: the vault is reported', said('ok', 'files indexed, state ready, schema 7'), true)
check('health: the index is up to date', said('ok', 'the index is up to date'), true)
check('health: the unknown tag is listed', said('info', 'nothing in the setup knows'), true)
local unknown
for _, r in ipairs(report) do
  if r[1] == 'info' and r[2]:find('nothing in the setup knows') then unknown = r[3] end
end
check('only the unknown one', unknown, { 'weird (1)' })
vim.fn.writefile({ '  I. A', 'changed again' }, base .. '/a.fey')
report = {}
require('fey.health').check_vaults()
check('health: a stale index is a warning', said('warn', 'stale for 1 file'), true)

-- the toggles, the help and the mappings --------------------------------------------------------------------------------------
vim.cmd('edit ' .. vim.fn.fnameescape(base .. '/new.fey'))
vim.bo.filetype = 'fey'
local M = require('fey').fey_mappings
config:extend({ fey_link_conceal_default = false, fey_query_conceal_default = false, fey_highlight_overdue = true })
M:toggle_option('fey_link_conceal_default')
check('a toggle turns an option on', config.fey_link_conceal_default, true)
M:toggle_option('fey_link_conceal_default')
check('and off', config.fey_link_conceal_default, false)
M:toggle_option('fey_highlight_overdue')
check('overdue', config.fey_highlight_overdue, false)
config:extend({ fey_highlight_overdue = true })
local prefix = config.mappings.prefix or '<Leader>;'
local function mapped(lhs) return vim.fn.maparg(vim.api.nvim_replace_termcodes(prefix .. lhs, true, false, true), 'n') ~= '' end
check('the tree of toggles', { mapped('Tc'), mapped('Tl'), mapped('Tq'), mapped('Ti'), mapped('To'), mapped('Te'), mapped('Ts') }, { true, true, true, true, true, true, true })
check('the old keys of the toggles work', { mapped('!e'), mapped('?e') }, { true, true })
check('the commands of the finished features are on', { mapped('*'), mapped('iT'), mapped('it'), vim.fn.maparg('g?', 'n') ~= '' }, { true, true, true, true })

local Help = require('fey.objects.help')
for _, kind in ipairs({ 'fey', 'agenda', 'capture', 'edit_src' }) do
  local ok, err = pcall(Help.show, kind)
  local lines = ok and vim.api.nvim_buf_get_lines(0, 0, -1, false) or {}
  check('help ' .. kind .. ' shows ' .. tostring(err or ''), { ok, #lines > 3 }, { true, true })
  if ok then vim.cmd('close') end
end
local lines
Help.show('fey')
lines = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
check('the help lists the toggles', lines:find('Hide the head of links', 1, true) ~= nil, true)
vim.cmd('close')

vault:close()
print(('health: %d checks, %d failures'):format(total, failures))
vim.cmd(failures == 0 and 'qa!' or 'cq!')
