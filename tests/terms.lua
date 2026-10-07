-- The words of orgmode that Fey says differently (III.R): the old names of options and mappings are moved, the old names of the Lua API
-- keep working and say so, and nothing new is written in the old words. Run from the repo root:
--
--   FEY_PARSER=/path/to/fey.so nvim --headless --clean -l tests/terms.lua
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
local migrate = require('fey.config.migrate')
local defaults = require('fey.config.defaults')

-- the defaults say the new words ------------------------------------------------------------------------------
check('the new options are there', { defaults.fey_date_rounding_minutes ~= nil, defaults.fey_use_label_inheritance ~= nil, defaults.fey_agenda_remove_labels ~= nil }, { true, true, true })
check('the old options are not', { defaults.fey_time_stamp_rounding_minutes, defaults.fey_use_tag_inheritance, defaults.fey_agenda_remove_tags }, {})
local fey_keys = defaults.mappings.fey
local agenda_keys = defaults.mappings.agenda
check('the new mappings are there', { fey_keys.fey_date_up, fey_keys.fey_date_insert, fey_keys.fey_toggle_date_type, fey_keys.fey_set_labels_command, agenda_keys.fey_agenda_set_labels }, { '<C-a>', '<prefix>i.', '<prefix>d!', '<prefix>sl', '<prefix>t' })
check('the old mappings are not', { fey_keys.fey_timestamp_up, fey_keys.fey_time_stamp, fey_keys.fey_set_tags_command, agenda_keys.fey_agenda_set_tags }, {})

-- the migration ----------------------------------------------------------------------------------------------------
local given = { fey_use_tag_inheritance = true, fey_math_tag_name = 'tex', mappings = { fey = { fey_timestamp_up = '<C-q>', fey_time_stamp = '<C-t>' }, agenda = { fey_agenda_set_tags = 'T' } } }
local moved, notes = migrate.apply(given)
check('options move', { moved.fey_use_label_inheritance, moved.fey_use_tag_inheritance }, { true, nil })
check('mappings move, in every group', { moved.mappings.fey.fey_date_up, moved.mappings.fey.fey_date_insert, moved.mappings.agenda.fey_agenda_set_labels, moved.mappings.fey.fey_timestamp_up }, { '<C-q>', '<C-t>', 'T', nil })
check('what is not old stays', moved.fey_math_tag_name, 'tex')
check('what the user wrote is not changed', given.fey_use_tag_inheritance, true)
check('it says what it moved', #notes, 4)
check('a note names the old and the new', notes[1], 'the mapping `mappings.agenda.fey_agenda_set_tags` is now `fey_agenda_set_labels`')
check('the new name wins over the old', migrate.apply({ fey_use_tag_inheritance = true, fey_use_label_inheritance = false }).fey_use_label_inheritance, false)
check('a note with the old option names (the plugin tag)', migrate.options({ fey_agenda_remove_tags = true, fey_math_tag_name = 'x' }), { fey_agenda_remove_labels = true, fey_math_tag_name = 'x' })

-- setup uses the new names, and says it ------------------------------------------------------------------------------
local warned = {}
local notify = vim.notify
vim.notify = function(msg) warned[#warned + 1] = msg end
require('fey').setup({
  fey_court_dir = base .. '/court',
  fey_use_tag_inheritance = true,
  mappings = { fey = { fey_timestamp_up = '<C-q>' } },
})
vim.notify = notify
local config = require('fey.config')
check('setup warns once for each old name', warned, {
  'fey: the mapping `mappings.fey.fey_timestamp_up` is now `fey_date_up`',
  'fey: the option `fey_use_tag_inheritance` is now `fey_use_label_inheritance`',
})
check('and uses the option', config.fey_use_label_inheritance, true)
check('and the mapping', config.mappings.fey.fey_date_up, '<C-q>')
check('health lists the old names the setup was given', #migrate.find(require('fey').given_options()), 2)
config:extend({ fey_use_label_inheritance = false })

-- a note may use the old option names ---------------------------------------------------------------------------------------
check('the plugin tag handler takes the old names', (function()
  local handler = require('fey.settings').plugin_handlers.fey
  local ignored = {}
  handler.apply({ fey_agenda_remove_tags = true }, ignored, true)
  local ok = config.opts.fey_agenda_remove_labels == true and next(ignored) == nil
  handler.apply({}, {}, false)
  return ok
end)(), true)

-- the old names of the Lua API keep working and say so ---------------------------------------------------------------------
local deprecated = {}
local deprecate = vim.deprecate
vim.deprecate = function(name, alternative) deprecated[#deprecated + 1] = name .. ' -> ' .. alternative end
vim.fn.writefile({ '{# table; title: T #}', '', '  I. Task {# labels, a, b #}', '{# deadline, 2026-10-09 Fri #}' }, base .. '/a.fey')
vim.cmd('edit ' .. vim.fn.fnameescape(base .. '/a.fey'))
vim.bo.filetype = 'fey'
vim.treesitter.start(0, 'fey')
local file = require('fey.files.file'):new({ filename = base .. '/a.fey', buf = vim.api.nvim_get_current_buf() })
local heading = file:get_closest_heading({ 3, 0 })
check('Heading:get_tags is get_labels', { (heading:get_tags()) }, { { 'a', 'b' } })
check('Heading:has_tag', { heading:has_tag('a'), heading:has_label('a') }, { true, true })
check('Heading:tags_to_string', heading:tags_to_string(), heading:labels_to_string())
check('Heading:get_plan_dates', vim.deep_equal({ heading:get_plan_dates() }, { heading:get_planning_dates() }), true)
check('FeyFile:get_directive is get_data_key', file:get_directive('title'), 'T')
check('utils.tags_to_string', require('fey.utils').tags_to_string({ 'x', 'y' }), require('fey.utils').labels_to_string({ 'x', 'y' }))
check('an old name says so once per call', #deprecated, 6)
check('and what to use', deprecated[1], 'Heading:get_tags -> get_labels')
vim.deprecate = deprecate

-- nothing new in the old words -------------------------------------------------------------------------------------------------
local function terms(mode)
  local result = vim.system({ 'nvim', '--headless', '--clean', '-l', 'scripts/terms.lua', mode }, { text = true, env = { FEY_PARSER = vim.env.FEY_PARSER } }):wait()
  return result.code, result.stdout .. result.stderr
end
local code = terms('--check')
check('no new use of an old word', code, 0)
local leak = vim.fn.getcwd() .. '/lua/fey/zz_terms_probe.lua'
vim.fn.writefile({ '-- the headline of a probe, get_tags, fey_use_tag_inheritance' }, leak)
local code_leak, output = terms('--check')
vim.fn.delete(leak)
check('a new use fails the check', code_leak, 1)
check('and says where', output:find('zz_terms_probe.lua', 1, true) ~= nil, true)
check('the check passes again', (terms('--check')), 0)
local inventory_code, inventory = terms('')
check('the inventory lists every word', { inventory_code, inventory:find('headline', 1, true) ~= nil, inventory:find('tags of a heading', 1, true) ~= nil }, { 0, true, true })

print(('terms: %d checks, %d failures'):format(total, failures))
vim.cmd(failures == 0 and 'qa!' or 'cq!')
