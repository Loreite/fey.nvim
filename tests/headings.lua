-- The heading commands on a Fey outline. Run from the repo root:
--
--   FEY_PARSER=/path/to/fey.so nvim --headless --clean -l tests/headings.lua
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
require('fey').setup({ fey_court_dir = base .. '/court' })
local M = require('fey').fey_mappings

local SAMPLE = {
  '  I. First', --  1
  '', --                    2
  'text one', --            3
  '', --                    4
  '  I.A. Child one', --    5
  '', --                    6
  'body', --                7
  '', --                    8
  '  I.B. Child two', --    9
  '', --                    10
  '  II. Second', --        11
  '', --                    12
  '-  item', --             13
  '   -  nested', --        14
  '', --                    15
  '  II.A. Child', --       16
  '', --                    17
  'last', --                18
}
local function fresh(row, lines)
  vim.fn.writefile(lines or SAMPLE, base .. '/a.fey')
  vim.cmd('edit! ' .. vim.fn.fnameescape(base .. '/a.fey'))
  vim.bo.filetype = 'fey'
  vim.treesitter.start(0, 'fey')
  vim.wo.foldenable = false
  vim.api.nvim_win_set_cursor(0, { row, 0 })
end
local function text() return vim.api.nvim_buf_get_lines(0, 0, -1, false) end
local function row() return vim.api.nvim_win_get_cursor(0)[1] end

-- navigation ------------------------------------------------------------------------------------------
fresh(5)
M:next_visible_heading()
check('next heading', row(), 9)
M:next_visible_heading()
check('next heading, any level', row(), 11)
M:previous_visible_heading()
check('previous heading', row(), 9)
fresh(5)
M:forward_heading_same_level()
check('forward, same level', row(), 9)
M:backward_heading_same_level()
check('backward, same level', row(), 5)
M:outline_up_heading()
check('up the outline', row(), 1)
fresh(11)
M:last_child_heading()
check('last child', row(), 16)

-- toggle ------------------------------------------------------------------------------------------------
fresh(5)
M:toggle_heading()
check('a heading becomes plain text', { text()[5], text()[9] }, { 'Child one', '  I.A. Child two' })
fresh(3)
M:toggle_heading()
check('a plain line becomes a child heading', { text()[3], text()[5] }, { '  I.A. text one', '  I.B. Child one' })
check('no stars of org', #vim.tbl_filter(function(l) return l:match('^%*') end, text()), 0)
fresh(13)
M:toggle_heading()
check('a list item becomes a child heading', { text()[13], text()[16] }, { '  II.A. item', '  II.B. Child' })
fresh(1, { 'a plain line', '', '  I. Heading' })
M:toggle_heading()
check('a line above every heading is a top level heading', text()[1], '  I. a plain line')
local BOXES = { '  I. H', '', '-  [x] done thing', '-  [ ] open thing', '-  [/] half thing' }
fresh(3, BOXES)
M:toggle_heading()
check('a checked box becomes a done status', text()[3], '  I.A. {# status, DONE #} done thing')
fresh(4, BOXES)
M:toggle_heading()
check('an open box becomes a todo status', text()[4], '  I.A. {# status, TODO #} open thing')
fresh(5, BOXES)
M:toggle_heading()
check('another state is only text', text()[5], '  I.A. half thing')

-- move -------------------------------------------------------------------------------------------------------
fresh(9)
M:move_subtree_up()
check('move up swaps with the neighbour and renumbers', { text()[5], text()[7] }, { '  I.A. Child two', '  I.B. Child one' })
check('the body went with it', text()[9], 'body')
check('the cursor stays on the heading', row(), 5)
fresh(5)
M:move_subtree_down()
check('move down', { text()[5], text()[7], text()[9] }, { '  I.A. Child two', '  I.B. Child one', 'body' })
check('cursor follows', row(), 7)
fresh(5)
vim.wo.foldenable = true
vim.cmd('normal! zxzM')
M:move_subtree_down()
check('moving a heading in a closed fold does not move it into itself', { text()[5], text()[7], text()[9] }, { '  I.A. Child two', '  I.B. Child one', 'body' })
fresh(1)
M:move_subtree_up()
check('the first of its level does not move', text(), SAMPLE)
fresh(11)
M:move_subtree_down()
check('the last of its level does not move', text(), SAMPLE)

-- insert ---------------------------------------------------------------------------------------------------------
fresh(5)
M:insert_heading_respect_content('', false)
vim.cmd('stopinsert')
check('a new heading after the content, same level', text()[10], '  I.A. ')
fresh(5)
M:insert_heading_respect_content('', true)
vim.cmd('stopinsert')
check('a new subheading', text()[10], '  I.A.i. ')
fresh(5)
M:insert_todo_heading_respect_content(false)
vim.cmd('stopinsert')
check('a todo heading has a status tag', text()[10], '  I.A. {# status, TODO #} ')
fresh(5)
M:insert_todo_heading(false)
vim.cmd('stopinsert')
check('a todo heading under the cursor line too', vim.tbl_contains(text(), '  I.A. {# status, TODO #} '), true)

-- promote, demote ------------------------------------------------------------------------------------------------
fresh(5)
M:do_demote(false)
check('demote', text()[5], '  I.A.i. Child one')
fresh(5)
M:do_promote(false)
check('promote renumbers', { text()[5], text()[9], text()[11] }, { '  II. Child one', '  II.A. Child two', '  III. Second' })

-- folding --------------------------------------------------------------------------------------------------------------
fresh(1)
vim.wo.foldenable = true
vim.cmd('normal! zxzR')
M:cycle()
check('cycling a heading with children folds it', vim.fn.foldclosed(1), 1)
M:cycle()
check('cycling again opens it', vim.fn.foldclosed(1), -1)
M.global_cycle_mode = 'all'
M:global_cycle()
check('global cycle: contents', M.global_cycle_mode, 'Contents')
M:global_cycle()
check('global cycle: show all', { M.global_cycle_mode, vim.fn.foldclosed(1) }, { 'Show All', -1 })
M:global_cycle()
check('global cycle: overview', { M.global_cycle_mode, vim.fn.foldclosed(1) ~= -1 }, { 'Overview', true })

print(('headings: %d checks, %d failures'):format(total, failures))
vim.cmd(failures == 0 and 'qa!' or 'cq!')
