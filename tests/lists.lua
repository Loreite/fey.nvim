-- Reindexing a list: sublists of one item and their index types. Run from the repo root:
--
--   FEY_PARSER=/path/to/fey.so nvim --headless --clean -l tests/lists.lua
vim.opt.rtp:prepend('.')
if vim.env.FEY_PARSER then vim.treesitter.language.add('fey', { path = vim.env.FEY_PARSER }) end
require('fey.config'):extend({})
require('fey.config'):setup_ts_predicates()

local FeyFile = require('fey.files.file')
local config = require('fey.config')

local failures, total = 0, 0
local function check(name, got, want)
  total = total + 1
  if not vim.deep_equal(got, want) then
    failures = failures + 1
    print(('FAIL %s\n  got:  %s\n  want: %s'):format(name, vim.inspect(got), vim.inspect(want)))
  end
end

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, 'p')
local n = 0
local function reindexed(input)
  n = n + 1
  local name = ('%s/t%d.fey'):format(dir, n)
  vim.fn.writefile(input, name)
  vim.cmd('edit ' .. vim.fn.fnameescape(name))
  local buf = vim.api.nvim_get_current_buf()
  vim.b[buf].did_ftplugin = true
  vim.bo[buf].filetype = 'fey'
  vim.treesitter.start(buf, 'fey')
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  FeyFile:new({ filename = name, buf = buf }):reindex_list()
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

-- on (the default): each sublist keeps its type and counts from its own start; text splits a list in two
check('default is on', config.fey_sublists_allow_mixed_index_types, true)
local split = {
  '1.  Parent',
  '    1.  one',
  '    3.  two',
  '',
  '    text between',
  '',
  '    a.  alpha',
  '    c.  beta',
  '2.  Next',
  '    1.  again',
}
check('mixed types are kept, counts repaired', reindexed(split), {
  '1.  Parent',
  '    1.  one',
  '    2.  two',
  '',
  '    text between',
  '',
  '    a.  alpha',
  '    b.  beta',
  '2.  Next',
  '    1.  again',
})

config.fey_sublists_allow_mixed_index_types = false
check('off: the second sublist takes the first type', reindexed(split), {
  '1.  Parent',
  '    1.  one',
  '    2.  two',
  '',
  '    text between',
  '',
  '    3.  alpha',
  '    4.  beta',
  '2.  Next',
  '    1.  again',
})
config.fey_sublists_allow_mixed_index_types = true

print(('%d checks, %d failed'):format(total, failures))
vim.cmd(failures == 0 and 'qa!' or 'cq!')
