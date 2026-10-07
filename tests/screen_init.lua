-- A minimal Neovim config for tests/screen.sh: the plugin from the repo, the parser from FEY_PARSER, and the
-- plugin options in FEY_OPTS (a Lua table written as text).
vim.opt.rtp:prepend(vim.env.FEY_ROOT)
vim.treesitter.language.add('fey', { path = vim.env.FEY_PARSER })
vim.cmd('filetype plugin indent on')
vim.cmd('syntax on')
vim.o.swapfile = false
local extra = vim.env.FEY_OPTS and load('return ' .. vim.env.FEY_OPTS)() or {}
require('fey').setup(vim.tbl_extend('force', { fey_court_dir = vim.fn.tempname() .. '/court' }, extra))
