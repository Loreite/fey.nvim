-- Variables (`var` tag): definitions, scope insertions on export, `$var$` interpolation in tags on execution and export,
-- vault scope chain (local -> hollow -> parent hollow -> court), shadowing, and `vault:path:to:var` references.
--
--   nvim --headless --clean -l tests/vars.lua
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

local function has(s, needle) return s ~= nil and s:find(needle, 1, true) ~= nil end

local base = vim.uv.fs_realpath((function()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, 'p')
  return d
end)())

local court_dir = base .. '/court'
local parent_dir = base .. '/workspace'
local sub_dir = parent_dir .. '/subproject'

vim.fn.mkdir(court_dir .. '/.fey', 'p')
vim.fn.mkdir(parent_dir .. '/.fey', 'p')
vim.fn.mkdir(sub_dir .. '/.fey/subdir', 'p')
vim.fn.mkdir(sub_dir .. '/subdir', 'p')

require('fey').setup({ fey_court_dir = court_dir })

local tree = require('fey.hollow.tree')
local vault_mod = require('fey.vault')
local vars = require('fey.vars')
local Export = require('fey.export')
local Tag = require('fey.files.elements.tags')
local edit = require('fey.files.elements.tags.edit')

local function write_file(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  vim.fn.writefile(lines, path)
end

-- 1. Set up court, parent hollow, and subhollow files with variables -----------------------------------------
write_file(court_dir .. '/globals.fey', {
  '  I. Court Globals',
  '#[ var, court_only ] https://court.example.org#',
  '#[ var, name: shadowed ] from_court#',
  '[ var, multi_court ]#',
  '   Court block text',
})

write_file(parent_dir .. '/.fey/hollow.fey', {
  '{# table; name: workspace #}',
})
write_file(parent_dir .. '/shared.fey', {
  '  I. Workspace Shared',
  '#[ var, parent_only ] https://workspace.example.org#',
  '#[ var, shadowed ] from_parent#',
})

write_file(sub_dir .. '/.fey/hollow.fey', {
  '{# table; name: subproject #}',
})
write_file(sub_dir .. '/defs.fey', {
  '  I. Subproject Defs',
  '#[ var, sub_only ] https://sub.example.org#',
  '#[ var, shadowed ] from_sub#',
  '[ var, pair_var #]',
  'Pair body text',
  '[# var ]',
})
write_file(sub_dir .. '/subdir/deep.fey', {
  '  I. Deep File',
  '#[ var, name: deep_var ] deep_value_123#',
  '#[ var; name: semi_var ] semi_value_456#',
})

-- Register hollows in the tree (court -> workspace -> subproject)
require('fey.hollow.court').ensure_dirs()
tree.register(parent_dir, 'workspace')
tree.register(sub_dir, 'subproject')

-- Open & sync vaults
local court_vault = vault_mod.open(court_dir)
court_vault:sync()
local parent_vault = vault_mod.open(parent_dir)
parent_vault:sync()
local sub_vault = vault_mod.open(sub_dir)
sub_vault:sync()

-- 2. Vault table indexing & API ------------------------------------------------------------------------------
local sub_vars = sub_vault:vars({ name = 'pair_var' })
check('pair_tag var indexed in vault', { #sub_vars, sub_vars[1] and sub_vars[1].value }, { 1, 'Pair body text' })

local deep_vars = sub_vault:vars({ path = 'subdir/deep.fey' })
check('name: and ; name: syntax indexed in vault', {
  #deep_vars,
  deep_vars[1] and deep_vars[1].name,
  deep_vars[1] and deep_vars[1].value,
  deep_vars[2] and deep_vars[2].name,
  deep_vars[2] and deep_vars[2].value,
}, { 2, 'deep_var', 'deep_value_123', 'semi_var', 'semi_value_456' })

-- 3. Vault scope lookup & shadowing --------------------------------------------------------------------------
local note_in_sub = sub_dir .. '/note.fey'
check('lookup court var from subhollow', vars.get('court_only', { path = note_in_sub }), 'https://court.example.org')
check('lookup parent var from subhollow', vars.get('parent_only', { path = note_in_sub }), 'https://workspace.example.org')
check('lookup subhollow var from subhollow', vars.get('sub_only', { path = note_in_sub }), 'https://sub.example.org')
check('subhollow shadows parent and court', vars.get('shadowed', { path = note_in_sub }), 'from_sub')

local note_in_parent = parent_dir .. '/note.fey'
check('parent hollow shadows court', vars.get('shadowed', { path = note_in_parent }), 'from_parent')
check('court var visible from parent hollow', vars.get('court_only', { path = note_in_parent }), 'https://court.example.org')

-- Local buffer/document shadows subhollow, parent, and court
local local_src = table.concat({
  '#[ var, shadowed ] from_local_doc#',
  '#[ var, local_only ] local_val#',
}, '\n')
check('local document shadows vault hierarchy', vars.get('shadowed', { path = note_in_sub, src = local_src }), 'from_local_doc')
check('local document var resolves', vars.get('local_only', { path = note_in_sub, src = local_src }), 'local_val')

-- 4. Qualified `vault:path:to:var` lookups -------------------------------------------------------------------
check('court:var bypasses local shadowing', vars.get('court:shadowed', { path = note_in_sub, src = local_src }), 'from_court')
check('court:globals:shadowed resolves file in court', vars.get('court:globals:shadowed', { path = note_in_sub }), 'from_court')
check(
  'court:workspace:shadowed resolves parent hollow',
  vars.get('court:workspace:shadowed', { path = note_in_sub, src = local_src }),
  'from_parent'
)
check(
  'workspace:shadowed resolves registered hollow from court',
  vars.get('workspace:shadowed', { path = note_in_sub, src = local_src }),
  'from_parent'
)
check(
  'workspace:subproject:subdir:deep:deep_var resolves nested path',
  vars.get('workspace:subproject:subdir:deep:deep_var', { path = note_in_parent }),
  'deep_value_123'
)
check(
  'court:workspace:subproject:subdir:deep:semi_var resolves full chain',
  vars.get('court:workspace:subproject:subdir:deep:semi_var', { path = note_in_parent }),
  'semi_value_456'
)
check(
  'current:subdir:deep:deep_var resolves from current hollow',
  vars.get('current:subdir:deep:deep_var', { path = note_in_sub }),
  'deep_value_123'
)
check(
  'slash notation court:workspace/shared.fey:parent_only',
  vars.get('court:workspace/shared.fey:parent_only', { path = note_in_sub }),
  'https://workspace.example.org'
)

-- 5. Export: scope tag insertion & tag interpolation ---------------------------------------------------------
local export_src = table.concat({
  '  I. Export Test',
  '',
  '#[ var, url1 ] https://gitlab.com/rrml/webd/realm/site.git#',
  '#[ var, name: link_label ] Realm Site#',
  '[ var, snippet ]#',
  '   inserted from block var',
  '',
  '[ var, pair_snip #]',
  'inserted from pair var',
  '[# var ]',
  '',
  'Inline var: {# var, link_label #} and {# var, name: pair_snip #}.',
  '',
  'From parent vault: {# var, parent_only #} and qualified {# var, court:shadowed #}.',
  '',
  '{# var, snippet #}',
  '',
  '| a table is a useful case for this |',
  '| {# link; url: $url1$ #}           |',
  '',
  'Named link: {# link, $url1$; desc: $link_label$ #} and court link {# link; url: $court:court_only$; desc: Court #}.',
}, '\n') .. '\n'

local md_out = Export.markdown(export_src, { path = note_in_sub })
check('var definitions are not emitted in markdown export', {
  has(md_out, '#[ var'),
  has(md_out, '[ var'),
  has(md_out, '[# var'),
}, { false, false, false })
check(
  'inline {# var, name #} and {# var, name: ... #} insert variable text on export',
  has(md_out, 'Inline var: Realm Site and inserted from pair var.'),
  true
)
check(
  'vault and qualified vars insert on export',
  has(md_out, 'From parent vault: https://workspace.example.org and qualified from\\_court.'),
  true
)
check('standalone block {# var, snippet #} inserts paragraph on export', has(md_out, 'inserted from block var'), true)
check(
  'table cell {# link; url: $url1$ #} resolves url on export',
  has(md_out, '[site](https://gitlab.com/rrml/webd/realm/site.git)'),
  true
)
check('link with $url1$ and $link_label$ and $court:court_only$ resolves on export', {
  has(md_out, '[Realm Site](https://gitlab.com/rrml/webd/realm/site.git)'),
  has(md_out, '[Court](https://court.example.org)'),
}, { true, true })

local html_out = Export.html(export_src, { path = note_in_sub })
check('HTML export resolves {# var #} and {# link; url: $url1$ #}', {
  has(html_out, 'Inline var: Realm Site and inserted from pair var.'),
  has(html_out, '<a href="https://gitlab.com/rrml/webd/realm/site.git">site</a>'),
  has(html_out, '<a href="https://gitlab.com/rrml/webd/realm/site.git">Realm Site</a>'),
}, { true, true, true })

-- 6. Execution in buffers: Tag.parse_tag_node, links, hl, nvim, tblfm ---------------------------------------
local buf = vim.api.nvim_create_buf(false, false)
vim.api.nvim_buf_set_name(buf, note_in_sub)
vim.api.nvim_set_current_buf(buf)
vim.bo[buf].filetype = 'fey'
vim.treesitter.start(buf, 'fey')
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  '  I. Buffer Test',
  '#[ var, url1 ] https://gitlab.com/rrml/webd/realm/site.git#',
  '#[ var, name: target_file ] defs.fey#',
  '#[ var, tax_rate ] 2#',
  '',
  '| a table is a useful case for this |',
  '| {# link; url: $url1$ #}           |',
  '',
  '{# link, $target_file$; desc: $court:shadowed$ #}',
  '{# nvim; tabstop: $tax_rate$ #}',
  '',
  '| qty | total |',
  '+=====+=======+',
  '| 5   |       |',
  '{# tblfm; total: qty * $tax_rate$ #}',
})

-- Parse link tag in table cell (line 7, 0-based row 6)
local cell_link = edit.at(buf, 6, 4)
check('table cell link tag resolves $url1$ on parse', {
  cell_link and cell_link.name,
  cell_link and cell_link.key_values.url,
  cell_link and cell_link.raw_key_values.url,
}, { 'link', 'https://gitlab.com/rrml/webd/realm/site.git', '$url1$' })

-- Parse file link tag with $target_file$ and $court:shadowed$ (line 9, 0-based row 8)
local file_link = edit.at(buf, 8, 2)
check('link tag resolves $target_file$ and $court:shadowed$', {
  file_link and file_link.values[1],
  file_link and file_link.key_values.desc,
}, { 'defs.fey', 'from_court' })

-- Execute nvim config tag with $tax_rate$ (line 10, 0-based row 9)
local nvim_tag = edit.at(buf, 9, 2)
if nvim_tag then nvim_tag:apply() end
check('nvim tag executes with resolved $tax_rate$', vim.bo[buf].tabstop, 2)

-- Execute table formula tag with $tax_rate$ (cursor on table row)
vim.api.nvim_win_set_cursor(0, { 12, 2 })
require('fey.files.elements.table.operations').recalculate()
local tbl_row = vim.api.nvim_buf_get_lines(buf, 13, 14, false)[1]
check('tblfm tag executes formula with resolved $tax_rate$', has(tbl_row, '10'), true)

-- Execute link tag with url: $url1$ via links.open_link
local opened_url
local orig_open = vim.ui.open
vim.ui.open = function(u)
  opened_url = u
  return true
end
require('fey.links').open_link(cell_link)
vim.ui.open = orig_open
check('opening {# link; url: $url1$ #} opens resolved URL', opened_url, 'https://gitlab.com/rrml/webd/realm/site.git')

if failures > 0 then
  print(('%d/%d checks failed'):format(failures, total))
  vim.cmd('cquit 1')
else
  print(('all %d checks passed'):format(total))
  vim.cmd('qall!')
end
