-- The documentation stays true to the code. Run from the repo root:
--
--   FEY_PARSER=/path/to/fey.so nvim --headless --clean -l tests/docs.lua
--
-- Checks: README.fey parses, the generated list of mappings is current, every mapping has a description, and
-- every public function of the Lua API is in doc/fey_api.txt.
local root = vim.fn.getcwd()
vim.opt.rtp:prepend(root)
if vim.env.FEY_PARSER then vim.treesitter.language.add('fey', { path = vim.env.FEY_PARSER }) end

local failures, total = 0, 0
local function check(name, got, want)
  total = total + 1
  if not vim.deep_equal(got, want) then
    failures = failures + 1
    print(('FAIL %s\n  got:  %s\n  want: %s'):format(name, vim.inspect(got), vim.inspect(want)))
  end
end

local function has_error(path)
  local text = table.concat(vim.fn.readfile(path), '\n')
  return vim.treesitter.get_string_parser(text, 'fey'):parse()[1]:root():has_error()
end

-- the README ----------------------------------------------------------------------------------------------
check('README.fey parses', has_error(root .. '/README.fey'), false)
check('TASKS.fey parses', has_error(root .. '/TASKS.fey'), false)
local docs = require('fey.docs.mappings')
local lines = vim.fn.readfile(root .. '/README.fey')
local replaced, err = docs.replace(lines)
check('the markers of the generated list are in the README', err, nil)
check('the list of mappings is current (run scripts/gen_mappings.lua)', replaced, lines)
local with_boxes, box_err = require('fey.docs.checkboxes').replace(lines)
check('the markers of the checkbox table are in the README', box_err, nil)
local current = docs.replace(with_boxes or {})
check('the table of checkbox states is current (run scripts/gen_mappings.lua)', current, lines)

-- the mappings ----------------------------------------------------------------------------------------------
local defaults = require('fey.config.defaults').mappings
local entries = require('fey.config.mappings')
for _, group in ipairs({ 'global', 'fey', 'agenda', 'capture', 'note', 'text_objects' }) do
  local undescribed = {}
  for name, value in pairs(defaults[group] or {}) do
    local entry = (entries[group] or {})[name]
    if entry and value ~= '' and value ~= false then
      local desc = entry.help_desc or (entry.opts and entry.opts.desc)
      if not desc or desc == '' then undescribed[#undescribed + 1] = name end
    end
  end
  table.sort(undescribed)
  check('every ' .. group .. ' mapping has a description', undescribed, {})
end
check('every default mapping has an entry', docs.orphans(), {})

-- the API reference -----------------------------------------------------------------------------------------
local reference = table.concat(vim.fn.readfile(root .. '/doc/fey_api.txt'), '\n')
local function public(file, pattern)
  local out = {}
  for line in io.lines(root .. '/lua/fey/api/' .. file) do
    local name = line:match(pattern)
    if name and name:sub(1, 1) ~= '_' then out[#out + 1] = name end
  end
  return out
end
local function missing(file, pattern, tag)
  local out = {}
  for _, name in ipairs(public(file, pattern)) do
    if not reference:find(('*%s%s()*'):format(tag, name), 1, true) then out[#out + 1] = name end
  end
  return out
end
check('every function of fey.api is documented', missing('init.lua', '^function FeyApi%.([%w_]+)', 'fey.api.'), {})
check('every function of FeyApiVault is documented', missing('vault.lua', '^function FeyVault:([%w_]+)', 'FeyApiVault:'), {})
check('every function of FeyApiFile is documented', missing('file.lua', '^function FeyFile:([%w_]+)', 'FeyApiFile:'), {})
check('every function of FeyApiHeading is documented', missing('heading.lua', '^function FeyHeading:([%w_]+)', 'FeyApiHeading:'), {})
check('every function of FeyApiCourt is documented', missing('court.lua', '^function FeyCourt%.([%w_]+)', 'FeyApiCourt.'), {})
check('every function of FeyApiAgenda is documented', missing('agenda.lua', '^function FeyAgenda%.([%w_]+)', 'FeyApiAgenda.'), {})
check('the schema lists every table', (function()
  local out = {}
  for _, t in ipairs({ 'files', 'headings', 'tags', 'links', 'labels', 'properties', 'dates', 'tasks' }) do
    if not reference:find('\n    ' .. t .. ' ', 1, true) then out[#out + 1] = t end
  end
  return out
end)(), {})

-- every configuration option is typed -----------------------------------------------------------------------
local meta = table.concat(vim.fn.readfile(root .. '/lua/fey/config/_meta.lua'), '\n')
local untyped = {}
for _, key in ipairs({ 'fey_court_dir', 'fey_agenda_scope', 'fey_agenda_show_scope', 'fey_agenda_show_hollow', 'fey_agenda_skip_archived', 'fey_refile_scope', 'fey_refile_leave_link', 'fey_status_tag_name', 'fey_labels_tag_name', 'fey_property_tag_name', 'fey_conceal_task_tags' }) do
  if not meta:find('---@field ' .. key .. '?', 1, true) and not meta:find('---@field ' .. key .. ' ', 1, true) then
    untyped[#untyped + 1] = key
  end
end
check('the options of phase one are in the config types', untyped, {})

-- the tutorial of the test vault, when FEY_TUTORIAL names it: its live tags must run without an error ---------
-- (it is run on a copy, so the vault itself is not touched)
local tutorial = vim.env.FEY_TUTORIAL
if tutorial and vim.fn.isdirectory(tutorial) == 1 then
  local copy = vim.fn.tempname()
  vim.fn.mkdir(copy, 'p')
  vim.fn.system({ 'cp', '-r', tutorial .. '/.', copy })
  vim.fn.delete(copy .. '/.fey/vault.db', 'rf')
  vim.fn.delete(copy .. '/.fey/vault.db-shm', 'rf')
  vim.fn.delete(copy .. '/.fey/vault.db-wal', 'rf')
  require('fey.config'):extend({ fey_court_dir = vim.fn.tempname() .. '/court' })
  check('the tutorial parses', has_error(copy .. '/README.fey'), false)
  local vault = require('fey.vault').open(copy)
  local done = false
  vault:scan({}, function() done = true end)
  vim.wait(30000, function() return done end, 20)
  vim.cmd('cd ' .. vim.fn.fnameescape(copy))
  vim.cmd('edit README.fey')
  vim.bo.filetype = 'fey'
  check('the live tags run', pcall(require('fey.query').run_all), true)
  vim.wait(3000)
  local errors = vim.tbl_filter(function(l) return l:match('^query error') or l:match('^feydb error') end, vim.api.nvim_buf_get_lines(0, 0, -1, false))
  check('and none of them is an error', errors, {})
end

if failures > 0 then
  print(('%d of %d checks failed'):format(failures, total))
  vim.cmd('cquit 1')
end
print(('ok: %d checks'):format(total))
vim.cmd('qa!')
