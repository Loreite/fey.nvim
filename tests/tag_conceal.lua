-- The conceal registry of tags: a fake tag that declares each mode. Run from the repo root:
--
--   FEY_PARSER=/path/to/fey.so nvim --headless --clean -l tests/tag_conceal.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
if vim.env.FEY_PARSER then vim.treesitter.language.add('fey', { path = vim.env.FEY_PARSER }) end
vim.cmd('filetype plugin indent on')
local config = require('fey.config')
config:extend({ fey_court_dir = vim.fn.tempname() .. '/court' })
config:setup_ts_predicates()

local failures, total = 0, 0
local function check(name, got, want)
  total = total + 1
  if not vim.deep_equal(got, want) then
    failures = failures + 1
    print(('FAIL %s\n  got:  %s\n  want: %s'):format(name, vim.inspect(got), vim.inspect(want)))
  end
end

local Tag = require('fey.files.elements.tags')
Tag.setup()
local conceal = require('fey.files.elements.tags.conceal')
conceal.clear()

local function buffer(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].filetype = 'fey'
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_win_set_cursor(0, { #lines, 0 })
  return bufnr
end

---What the buffer shows for one row: the text with the concealed columns removed, an icon in place of its range
local function shown(bufnr, row)
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, conceal.ns, { row, 0 }, { row, -1 }, { details = true })
  local hidden_line = false
  local cuts = {}
  local virt = ''
  for _, m in ipairs(marks) do
    local d = m[4]
    if d.conceal_lines then hidden_line = true end
    if d.conceal ~= nil then cuts[#cuts + 1] = { m[3], d.end_col, d.conceal } end
    if d.virt_text then
      for _, chunk in ipairs(d.virt_text) do virt = virt .. chunk[1] end
    end
  end
  if hidden_line then return nil end
  table.sort(cuts, function(a, b) return a[1] > b[1] end)
  for _, c in ipairs(cuts) do
    line = line:sub(1, c[1]) .. c[3] .. line:sub(c[2] + 1)
  end
  return virt .. line
end

local function apply(bufnr)
  local tags = Tag.parse_all_tags(bufnr)
  conceal.apply(bufnr, tags)
  return tags
end

-- no declaration, never concealed
local b = buffer({ 'text {# zz, one; k: two; conceal: true #} more', '' })
apply(b)
check('no declaration', shown(b, 0), 'text {# zz, one; k: two; conceal: true #} more')

-- hide
conceal.register('zz', { mode = 'hide', default = 'fey_zz_default' })
config.fey_zz_default = false
b = buffer({ 'text {# zz, one; conceal: true #} more', '', 'last' })
apply(b)
check('hide, scope tag', shown(b, 0), 'text  more')
b = buffer({ 'text {# zz, one #} more', '', 'last' })
apply(b)
check('no key, default false', shown(b, 0), 'text {# zz, one #} more')
config.fey_zz_default = true
apply(b)
check('no key, default true', shown(b, 0), 'text  more')
b = buffer({ 'text {# zz, one; conceal: false #} more', '', 'last' })
apply(b)
check('conceal: false beats the default', shown(b, 0), 'text {# zz, one; conceal: false #} more')
config.fey_zz_default = false

-- hide a pair tag: the opener and closer go, the body stays
b = buffer({ 'a [ zz; conceal: true #]coloured[# zz ] b', '', 'last' })
apply(b)
check('hide, pair tag inline', shown(b, 0), 'a coloured b')
b = buffer({ '[ zz; conceal: true #]', 'body', '[# zz ]', '', 'last' })
apply(b)
check('hide, pair tag opener line', shown(b, 0), nil)
check('hide, pair tag body stays', shown(b, 1), 'body')
check('hide, pair tag closer line', shown(b, 2), nil)

-- cursor on the tag: as written
b = buffer({ '[ zz; conceal: true #]', 'body', '[# zz ]', '', 'last' })
apply(b)
vim.api.nvim_win_set_cursor(0, { 2, 0 })
conceal.on_cursor(b)
check('cursor in the tag, opener', shown(b, 0), '[ zz; conceal: true #]')
check('cursor in the tag, closer', shown(b, 2), '[# zz ]')
vim.api.nvim_win_set_cursor(0, { 5, 0 })
conceal.on_cursor(b)
check('cursor away, hidden again', shown(b, 0), nil)

-- icon
conceal.register('zz', { mode = 'icon', icon = { nerd = 'N', unicode = 'U' } })
b = buffer({ 'text {# zz, one; conceal: true #} more', '', 'last' })
apply(b)
local icon = require('fey.colors.highlighter.checkbox_icons').style() == 'nerd' and 'N' or 'U'
check('icon', shown(b, 0), 'text ' .. icon .. ' more')
config.fey_conceal_icons = { zz = 'X' }
apply(b)
check('icon override', shown(b, 0), 'text X more')
config.fey_conceal_icons = {}

-- values: the chosen ones stay
conceal.register('zz', { mode = 'values', values = { 1, 'prio' }, hl = 'Title' })
b = buffer({ 'text {# zz, one, two; prio: A; conceal: true #} more', '', 'last' })
apply(b)
check('values, kept in place', shown(b, 0), 'text one A more')

-- values: virtual text in place of the head
conceal.register('zz', { mode = 'values', virtual = function(tag) return { { tag.values[1] .. '!', 'Title' } } end })
apply(b)
check('virtual text', shown(b, 0), 'one!text  more')

-- the query family, declared by handlers/conceal.lua: a query and its result are one object
conceal.clear()
require('fey.files.elements.tags.handlers.conceal').declare()
b = buffer({ '{# query, LIST FROM #a; conceal: true #}', '', '[ query_result; conceal: true #]', 'row', '[# query_result ]', '', 'last' })
apply(b)
local qicon = require('fey.colors.highlighter.checkbox_icons').style() == 'nerd' and '\u{f1c0}' or '≣'
check('query shows an icon', shown(b, 0), qicon)
check('result opener hidden', shown(b, 2), nil)
check('result body stays', shown(b, 3), 'row')
check('result closer hidden', shown(b, 4), nil)
vim.api.nvim_win_set_cursor(0, { 4, 0 })
conceal.on_cursor(b)
check('cursor in the result shows the query', shown(b, 0), '{# query, LIST FROM #a; conceal: true #}')

-- hl, declared by its handler
conceal.clear()
conceal.register('hl', require('fey.files.elements.tags.handlers.hl').conceal)
config.fey_query_conceal_default = false
b = buffer({ 'a [ hl; fg: red; conceal: true #]coloured[# hl ] b', '', 'a {# hl; fg: red #} b', '', 'last' })
apply(b)
check('hl conceal: true', shown(b, 0), 'a coloured b')
check('hl no key follows the default', shown(b, 2), 'a {# hl; fg: red #} b')
config.fey_query_conceal_default = true
apply(b)
check('hl default true', shown(b, 2), 'a  b')
config.fey_query_conceal_default = false

print(('%d checks, %d failed'):format(total, failures))
if failures > 0 then os.exit(1) end
vim.cmd('qa!')
