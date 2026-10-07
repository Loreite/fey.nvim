-- Math tags: their text is injected as LaTeX. Run from the repo root:
--
--   FEY_PARSER=/path/to/fey.so [LATEX_PARSER=/path/to/latex.so] nvim --headless --clean -l tests/math.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
if vim.env.FEY_PARSER then vim.treesitter.language.add('fey', { path = vim.env.FEY_PARSER }) end
local latex = vim.env.LATEX_PARSER or vim.fn.expand('~/.local/share/nvim/site/parser/latex.so')
if vim.fn.filereadable(latex) == 0 and not pcall(vim.treesitter.language.add, 'latex') then
  print('math: no latex parser, skipped')
  vim.cmd('qa!')
end
if vim.fn.filereadable(latex) == 1 then vim.treesitter.language.add('latex', { path = latex }) end
local config = require('fey.config')
config:extend({})
config:setup_ts_predicates()

local failures, total = 0, 0
local function check(name, got, want)
  total = total + 1
  if not vim.deep_equal(got, want) then
    failures = failures + 1
    print(('FAIL %s\n  got:  %s\n  want: %s'):format(name, vim.inspect(got), vim.inspect(want)))
  end
end

---The text of every injected latex region of some Fey text
local function regions(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = 'fey'
  local parser = vim.treesitter.get_parser(buf, 'fey')
  parser:parse(true)
  local out = {}
  local child = parser:children().latex
  for _, tree in ipairs(child and child:trees() or {}) do
    out[#out + 1] = vim.trim((vim.treesitter.get_node_text(tree:root(), buf):gsub('%s+', ' ')))
  end
  return out
end

check('a line tag', regions({ '  I. H', '', 'Inline #[ math ] \\frac{a}{b} # here' }), { '\\frac{a}{b}' })
check('a block tag', regions({ '  I. H', '', '[ math ]#', '   \\int_0^1 x \\, dx', '', 'after' }), { '\\int_0^1 x \\, dx' })
check('a pair tag', regions({ '  I. H', '', '[ math #]', '\\sum_{i=1}^n i', '[# math ]' }), { '\\sum_{i=1}^n i' })
check('a fenced block in latex', regions({ '  I. H', '', '###  src latex', '\\alpha + \\beta', '###' }), { '\\alpha + \\beta' })
check('another tag is not math', regions({ '  I. H', '', '#[ other ] \\nothing #' }), {})
config:extend({ fey_math_tag_name = 'tex' })
check('the tag name is an option', regions({ '  I. H', '', '#[ math ] a #', '', '#[ tex ] b #' }), { 'b' })
config:extend({ fey_math_tag_name = 'math' })

print(('math: %d checks, %d failures'):format(total, failures))
vim.cmd(failures == 0 and 'qa!' or 'cq!')
