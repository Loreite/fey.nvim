-- Indent and fold tests for blocks and block tags that open on a list bullet line. Run from the
-- repo root:
--
--   FEY_PARSER=/path/to/fey.so nvim --headless --clean -l tests/indent.lua
vim.opt.rtp:prepend('.')
if vim.env.FEY_PARSER then vim.treesitter.language.add('fey', { path = vim.env.FEY_PARSER }) end
require('fey.config'):extend({}):setup_ts_predicates()

local failures, total = 0, 0
local function check(name, got, want)
  total = total + 1
  if not vim.deep_equal(got, want) then
    failures = failures + 1
    print(('FAIL %s\n  got:  %s\n  want: %s'):format(name, vim.inspect(got), vim.inspect(want)))
  end
end

---Re-indent `lines` with `=` and return the lines and a fold probe
local function reindent(lines)
  local buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.b[buf].did_ftplugin = true
  vim.bo[buf].filetype = 'fey'
  vim.bo[buf].shiftwidth = 2
  vim.bo[buf].expandtab = true
  vim.bo[buf].indentexpr = 'v:lua.require("fey.fey.indent").indentexpr()'
  vim.treesitter.start(buf, 'fey')
  vim.wo.foldmethod = 'expr'
  vim.wo.foldexpr = 'v:lua.vim.treesitter.foldexpr()'
  vim.wo.foldlevel = 0
  vim.cmd('normal! zx')
  vim.cmd('silent normal! gg=G')
  local out = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local closed = {}
  for i = 1, #out do
    if vim.fn.foldclosed(i) ~= -1 then closed[#closed + 1] = vim.fn.foldclosed(i) .. '-' .. vim.fn.foldclosedend(i) end
  end
  return out, closed
end

-- the margin of a block on a bullet line is the bullet column: the closing fence has to sit there
-- (the scanner insists on it), the content keeps its indentation relative to it
local out, closed = reindent({
  '  I. Head', '', '-  ###  src lua', 'a = 1', '  b = 2', '###', '-  next:  y', '',
})
check('fence on bullet line', out, {
  '  I. Head', '', '-  ###  src lua', 'a = 1', '  b = 2', '###', '-  next:  y', '',
})
check('fence on bullet line folds', closed[1], '3-6')

-- nested: the margin is the bullet column of the nested item
out = reindent({
  '  I. Head', '', '-  outer:  text', '   -  ###  src lua', 'x', '###', '-  last:  z', '',
})
check('fence on nested bullet line', { out[4], out[5], out[6] }, { '   -  ###  src lua', '   x', '   ###' })

-- a block tag body is laid out two columns right of the bullet column
out, closed = reindent({
  '  I. Head', '', '-  [ note ]#  first', '       second', '           third', '       fourth', '-  next:  y', '',
})
check('block tag on bullet line', { out[3], out[4], out[5], out[6] }, {
  '-  [ note ]#  first', '  second', '      third', '  fourth',
})
check('block tag on bullet line folds', closed[1], '4-6')

if failures > 0 then
  print(('%d of %d checks failed'):format(failures, total))
  vim.cmd('cquit 1')
end
print(('ok: %d checks'):format(total))
vim.cmd('quit')
