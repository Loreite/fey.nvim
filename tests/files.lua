-- The files the editor keeps: nothing is loaded ahead, a file is loaded when asked for and forgotten with its buffer.
-- Run from the repo root:
--
--   FEY_PARSER=/path/to/fey.so nvim --headless --clean -l tests/files.lua
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
  vim.fn.mkdir(d .. '/notes', 'p')
  return d
end)())
for i = 1, 30 do
  vim.fn.writefile({ '  I. Note ' .. i, '', 'text' }, ('%s/notes/n%02d.fey'):format(base, i))
end
-- the old option names a glob of 30 files; it must not make the editor read them
require('fey').setup({ fey_court_dir = base .. '/court', fey_agenda_files = base .. '/notes/*.fey' })
local fey = require('fey')

check('nothing is loaded at startup', #fey.files:all(), 0)
check('the cache is not the glob', fey.files.paths, nil)
check('the preloading is gone', { fey.files.load, fey.files.load_sync, fey.files.find_headings_by_title, fey.files.get_tags }, {})

-- loaded on demand
vim.cmd('edit ' .. vim.fn.fnameescape(base .. '/notes/n03.fey'))
vim.bo.filetype = 'fey'
local file = fey.files:get_current_file()
check('the current file is loaded when asked for', { #fey.files:all(), vim.fn.fnamemodify(file.filename, ':t') }, { 1, 'n03.fey' })
check('and cached', fey.files:get_current_file() == file, true)
local heading = fey.files:get_closest_heading({ 1, 0 })
check('its headings work', heading:get_title(), 'Note 3')
check('another file by path', vim.fn.fnamemodify(fey.files:get(base .. '/notes/n07.fey').filename, ':t'), 'n07.fey')
check('now two', #fey.files:all(), 2)
check('listed by name', vim.tbl_map(function(f) return vim.fn.fnamemodify(f, ':t') end, fey.files:filenames()), { 'n03.fey', 'n07.fey' })
check('a file that is not there', fey.files:load_file_sync(base .. '/notes/missing.fey'), false)

-- reading again after the text changed
vim.fn.writefile({ '  I. Changed', '', 'text' }, base .. '/notes/n07.fey')
fey.files:reload(base .. '/notes/n07.fey'):wait()
check('reload reads again', fey.files:get(base .. '/notes/n07.fey'):get_closest_heading({ 1, 0 }):get_title(), 'Changed')

-- forgotten with the buffer
local buf = vim.api.nvim_get_current_buf()
vim.cmd('enew')
vim.api.nvim_buf_delete(buf, { force = true })
check('a wiped buffer is forgotten', vim.tbl_map(function(f) return vim.fn.fnamemodify(f, ':t') end, fey.files:filenames()), { 'n07.fey' })
fey.files:forget(base .. '/notes/n07.fey')
check('forget drops a file', #fey.files:all(), 0)

-- the workspace symbols come from the index
local root = base
vim.fn.mkdir(root .. '/.fey', 'p')
local vault = require('fey.vault').open(root)
local done = false
vault:scan({}, function() done = true end)
vim.wait(5000, function() return done end, 10)
vim.cmd('edit ' .. vim.fn.fnameescape(base .. '/notes/n05.fey'))
local symbols = require('fey.lsp.handlers')[vim.lsp.protocol.Methods.workspace_symbol]({ query = 'note 1' })
check('symbols of the whole hollow, none of them loaded', { #symbols > 0, #fey.files:all() }, { true, 0 })
check('symbol names', symbols[1].name:lower():find('note 1', 1, true) ~= nil, true)

vault:close()
print(('files: %d checks, %d failures'):format(total, failures))
vim.cmd(failures == 0 and 'qa!' or 'cq!')
