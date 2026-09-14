if vim.b.did_ftplugin or vim.b.fey_tmp_edit_window then
  return
end
---@diagnostic disable-next-line: inject-field
vim.b.did_ftplugin = true

local config = require('fey.config')

vim.treesitter.start()

local bufnr = vim.api.nvim_get_current_buf()

config:setup_mappings('fey', bufnr)
config:setup_mappings('text_objects', bufnr)
config:setup_foldlevel()

if config.fey_startup_indented then
  require('fey.ui.virtual_indent'):new(bufnr):attach()
end

vim.bo.modeline = false
vim.opt_local.fillchars:append('fold: ')
vim.opt_local.foldmethod = 'expr'
vim.opt_local.foldexpr = 'v:lua.vim.treesitter.foldexpr()'
if config.ui.folds.colored then
  vim.opt_local.foldtext = ''
else
  vim.opt_local.foldtext = 'v:lua.require("fey.fey.indent").foldtext()'
end
vim.opt_local.formatexpr = 'v:lua.require("fey.fey.format")()'
vim.opt_local.omnifunc = 'v:lua.fey.omnifunc'
vim.opt_local.commentstring = '# %s'
vim.bo.indentkeys = ('%s,%s'):format(vim.bo.indentkeys, '=~end_src,=~end_example,<:>')

_G.fey.omnifunc = function(findstart, base)
  return require('fey').completion:omnifunc(findstart, base)
end

local abbreviations = {
  [':today:'] = "require('fey.objects.date').today():to_wrapped_string(true)",
  [':now:'] = "require('fey.objects.date').now():to_wrapped_string(true)",
  [':itoday:'] = "require('fey.objects.date').today():to_wrapped_string(false)",
  [':inow:'] = "require('fey.objects.date').now():to_wrapped_string(false)",
}

for abbrev, cmd in pairs(abbreviations) do
  vim.cmd.inoreabbrev(('<silent><buffer> %s <C-R>=luaeval("%s")<CR>'):format(abbrev, cmd))
end

for _, char in ipairs({ '*', '=', '/', '+', '~', '_' }) do
  vim.keymap.set('x', 'i' .. char, ':<C-u>normal! T' .. char .. 'vt' .. char .. '<CR>', { buffer = true })
  vim.keymap.set('o', 'i' .. char, ':normal vi' .. char .. '<CR>', { buffer = true })
  vim.keymap.set('x', 'a' .. char, ':<C-u>normal! F' .. char .. 'vf' .. char .. '<CR>', { buffer = true })
  vim.keymap.set('o', 'a' .. char, ':normal va' .. char .. '<CR>', { buffer = true })
end

if config.fey_highlight_latex_and_related then
  vim.bo[bufnr].syntax = 'ON'
end

vim.b.undo_ftplugin = table.concat({
  'setlocal',
  'commentstring<',
  'foldmethod<',
  'modeline<',
  'foldtext<',
  'foldlevel<',
  'foldexpr<',
  'formatexpr<',
  'omnifunc<',
  'indentkeys<',
  '| unlet! b:fey_tmp_edit_window',
}, ' ')

-- Manually attach Snacks.image module to ensure that images are shown.
-- Snacks usually handles this automatically, but if Fey plugin is loaded after Snacks, it will not pick it up.
if
  vim.tbl_get(_G, 'Snacks', 'image', 'config', 'enabled') and vim.tbl_get(_G, 'Snacks', 'image', 'config', 'doc', 'enabled')
then
  require('snacks.image.doc').attach(bufnr)
end
