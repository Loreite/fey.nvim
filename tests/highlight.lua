-- Highlighting: the query compiles and gives dates their faces, overdue dates come from the index. Run from the repo root:
--
--   FEY_PARSER=/path/to/fey.so nvim --headless --clean -l tests/highlight.lua
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
  vim.fn.mkdir(d, 'p')
  return d
end)())
local config = require('fey.config')
require('fey').setup({ fey_court_dir = base .. '/court' })
local Date = require('fey.objects.date')

check('the highlight query compiles', pcall(vim.treesitter.query.get, 'fey', 'highlights'), true)
check('no query leftovers of org', vim.uv.fs_stat(vim.fn.getcwd() .. '/queries/fey/highlights.scm.org.bak'), nil)
check('no org keyword faces highlighter', pcall(require, 'fey.colors.highlighter.todos'), false)

local root = base .. '/hollow'
vim.fn.mkdir(root .. '/.fey', 'p')
local function day(offset) return Date.today():adjust((offset >= 0 and '+' or '') .. offset .. 'd'):to_tag_value() end
local lines = {
  '  I. {# status, TODO #} Late task',
  '{# deadline, ' .. day(-3) .. ' #} {# scheduled, ' .. day(-2) .. ' #}',
  '',
  '  II. {# status, TODO #} On time',
  '{# deadline, ' .. day(5) .. ' #}',
  '',
  '  III. {# status, DONE #} Finished late',
  '{# deadline, ' .. day(-9) .. ' #}',
  '',
  '  IV. No keyword',
  '{# deadline, ' .. day(-9) .. ' #}',
  '',
  'plain {@ date, ' .. day(-1) .. ' @} date',
}
vim.fn.writefile(lines, root .. '/late.fey')
local vault = require('fey.vault').open(root)
local done = false
vault:scan({}, function() done = true end)
vim.wait(5000, function() return done end, 10)

vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/late.fey'))
local buf = vim.api.nvim_get_current_buf()
vim.bo[buf].filetype = 'fey'
vim.treesitter.start(buf, 'fey')

-- faces of the dates, from the query
local function capture_at(row, col)
  local names = {}
  for _, c in ipairs(vim.treesitter.get_captures_at_pos(buf, row, col)) do
    names[#names + 1] = c.capture
  end
  return names
end
check('a deadline value has the deadline face', vim.tbl_contains(capture_at(1, 14), 'fey.date.deadline'), true)
check('a scheduled value has the scheduled face', vim.tbl_contains(capture_at(1, 46), 'fey.date.scheduled'), true)
check('a date value has the date face', vim.tbl_contains(capture_at(12, 16), 'fey.date'), true)
check('another tag is not a date', vim.tbl_contains(capture_at(0, 18), 'fey.date'), false)
local group = vim.api.nvim_get_hl(0, { name = '@fey.date.overdue', link = true })
check('the faces are defined', group.link, 'DiagnosticError')

-- overdue, from the index
local overdue = require('fey.colors.highlighter.overdue')
overdue.refresh(buf)
local marks = vim.api.nvim_buf_get_extmarks(buf, overdue.ns, 0, -1, { details = true })
local painted = vim.tbl_map(function(m) return m[2] .. ':' .. m[4].hl_group end, marks)
table.sort(painted)
check('the late deadline and the late scheduled date are painted', painted, { '1:@fey.date.overdue', '1:@fey.date.scheduled_past' })
config:extend({ fey_highlight_overdue = false })
overdue.refresh(buf)
check('switched off', #vim.api.nvim_buf_get_extmarks(buf, overdue.ns, 0, -1, {}), 0)
config:extend({ fey_highlight_overdue = true })
check('it is an option a note may set', require('fey.settings.fey_options').allowed('fey_highlight_overdue'), true)

-- the index of the file changes: the buffer is painted again
vim.api.nvim_buf_set_lines(buf, 4, 5, false, { '{# deadline, ' .. day(-1) .. ' #}' })
vault:index_text(root .. '/late.fey', vim.api.nvim_buf_get_lines(buf, 0, -1, false))
vim.wait(1000, function() return #vim.api.nvim_buf_get_extmarks(buf, overdue.ns, 0, -1, {}) == 3 end, 20)
check('an edit that makes a deadline late paints it', #vim.api.nvim_buf_get_extmarks(buf, overdue.ns, 0, -1, {}), 3)

vault:close()
print(('highlight: %d checks, %d failures'):format(total, failures))
vim.cmd(failures == 0 and 'qa!' or 'cq!')
