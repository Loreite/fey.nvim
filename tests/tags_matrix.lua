-- Every tag the plugin has, in every form it takes, goes through the same course: it parses, it is indexed, it is found at its position
-- by the editing code, the tag handlers can read it, the export and the completion know what to do with it. A new tag is one more line of
-- `SAMPLES`. Run from the repo root:
--
--   FEY_PARSER=/path/to/fey.so nvim --headless --clean -l tests/tags_matrix.lua
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
local config = require('fey.config')
local Tag = require('fey.files.elements.tags')
local edit = require('fey.files.elements.tags.edit')
local extract = require('fey.vault.extract')
local Export = require('fey.export')
local data = require('fey.fey.autocompletion.data')

-- name, form, a line (or lines) the tag is in; `row` is the line (0 based) it starts on
---@type { name: string, form: string, lines: string[], row: integer, col: integer }[]
local SAMPLES = {
  { 'status', 'scope_tag', { '  I. {# status, TODO, A #} Task' }, 0, 5 },
  { 'labels', 'scope_tag', { '  I. Heading {# labels, a, b #}' }, 0, 14 },
  { 'prop', 'scope_tag', { '  I. H', '{# prop; effort: 2h #}' }, 1, 0 },
  { 'date', 'scope_tag', { '  I. H', '', 'on {@ date, 2026-10-07 Wed @} then' }, 2, 3 },
  { 'scheduled', 'scope_tag', { '  I. H', '{# scheduled, 2026-10-07 Wed #}' }, 1, 0 },
  { 'deadline', 'scope_tag', { '  I. H', '{# deadline, 2026-10-07 Wed #}' }, 1, 0 },
  { 'closed', 'scope_tag', { '  I. H', '{# closed, 2026-10-07 Wed 10:00 #}' }, 1, 0 },
  { 'clock', 'scope_tag', { '  I. H', '[ logbook #]', '{# clock, 2026-10-06 Tue 10:00; end: 2026-10-06 Tue 11:00; dur: 1:00 #}', '[# logbook ]' }, 2, 0 },
  { 'logbook', 'pair_tag', { '  I. H', '[ logbook #]', '-  {@ date, 2026-10-06 Tue; active: false @}  Note taken: x', '[# logbook ]' }, 1, 0 },
  { 'logbook', 'block_tag', { '  I. H', '[ logbook ]#', '   -  {@ date, 2026-10-06 Tue; active: false @}  Note taken: x' }, 1, 0 },
  { 'fn', 'scope_tag', { '  I. H', '', 'a note {@ fn, one @} here' }, 2, 7 },
  { 'fn', 'pair_tag', { '  I. H', '', '[ fn, one #]', 'The note.', '[# fn ]' }, 2, 0 },
  { 'fn', 'block_tag', { '  I. H', '', '[ fn, one ]#', '   The note.' }, 2, 0 },
  { 'fn', 'line_tag', { '  I. H', '', '#[ fn, one ] The note. #' }, 2, 0 },
  { 'link', 'scope_tag', { '  I. H', '', 'see {@ link, other.fey; desc: Other @} now' }, 2, 4 },
  { 'link', 'line_tag', { '  I. H', '', '#[ link, other.fey ] words of the link #' }, 2, 0 },
  { 'link', 'block_tag', { '  I. H', '', '[ link, other.fey ]#', '   a paragraph that is the link' }, 2, 0 },
  { 'link', 'pair_tag', { '  I. H', '', '[ link, other.fey #]', 'a paragraph that is the link', '[# link ]' }, 2, 0 },
  { 'section', 'scope_tag', { '  I. H', '', 'see {@ section, I. @} now' }, 2, 4 },
  { 'comment', 'scope_tag', { '  I. H', '', 'word {# comment #} more' }, 2, 5 },
  { 'comment', 'line_tag', { '  I. H', '', '#[ comment ] hidden #' }, 2, 0 },
  { 'comment', 'block_tag', { '  I. H', '', '[ comment ]#', '   hidden' }, 2, 0 },
  { 'comment', 'pair_tag', { '  I. H', '', '[ comment #]', 'hidden', '[# comment ]' }, 2, 0 },
  { 'math', 'line_tag', { '  I. H', '', 'x #[ math ] a^2 # y' }, 2, 2 },
  { 'math', 'block_tag', { '  I. H', '', '[ math ]#', '   \\int x dx' }, 2, 0 },
  { 'math', 'pair_tag', { '  I. H', '', '[ math #]', '\\int x dx', '[# math ]' }, 2, 0 },
  { 'query', 'scope_tag', { '  I. H', '', '{# query, LIST WITHOUT ID file.name #}' }, 2, 0 },
  { 'query', 'block_tag', { '  I. H', '', '[ query ]#', '   LIST WITHOUT ID file.name' }, 2, 0 },
  { 'query_result', 'pair_tag', { '  I. H', '', '[ query_result #]', '-  x', '[# query_result ]' }, 2, 0 },
  { 'feydb', 'scope_tag', { '  I. H', '', '{# feydb, 5; db: projects #}' }, 2, 0 },
  { 'feydb_result', 'pair_tag', { '  I. H', '', '[ feydb_result #]', '| a |', '[# feydb_result ]' }, 2, 0 },
  { 'clocktable', 'scope_tag', { '  I. H', '', '{# clocktable; span: thisweek; by: file #}' }, 2, 0 },
  { 'clocktable_result', 'pair_tag', { '  I. H', '', '[ clocktable_result #]', '| a |', '[# clocktable_result ]' }, 2, 0 },
  { 'hl', 'scope_tag', { '  I. H', '', 'word {# hl; fg: red #} more' }, 2, 5 },
  { 'nvim', 'scope_tag', { '{# nvim; wrap: false #}', '', '  I. H' }, 0, 0 },
  { 'plugin', 'scope_tag', { '{# plugin, fey; fey_highlight_overdue: false #}', '', '  I. H' }, 0, 0 },
  { 'table', 'scope_tag', { '{# table; title: T; author: A #}', '', '  I. H' }, 0, 0 },
  { 'array', 'scope_tag', { '  I. H', '{# array, 1, 2, 3 #}' }, 1, 0 },
  { 'value', 'scope_tag', { '  I. H', '{# value, 5 #}' }, 1, 0 },
}

local function parses(lines)
  local src = table.concat(lines, '\n') .. '\n'
  local root = vim.treesitter.get_string_parser(src, 'fey'):parse()[1]:root()
  return not root:has_error(), src
end

local function open(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = 'fey'
  vim.api.nvim_set_current_buf(buf)
  vim.treesitter.start(buf, 'fey')
  return buf
end

for _, sample in ipairs(SAMPLES) do
  local name, form, lines, row, col = unpack(sample)
  local label = ('%s (%s)'):format(name, form)

  local ok, src = parses(lines)
  check(label .. ': parses', ok, true)

  -- indexed
  local meta = extract.extract(src, { prop_tag = config.fey_property_tag_name })
  local found = vim.tbl_filter(function(t) return t.name == name and t.kind == form:gsub('_tag$', '') end, meta.tags)
  -- (a tag a comment covers is not indexed, and the data of a file is read by its own code)
  check(label .. ': indexed as a tag', #found >= 1 or name == 'table', true)
  check(label .. ': no error while indexing', #meta.errors, 0)

  -- found at its position, and read by the handlers
  local buf = open(lines)
  local tag = edit.at(buf, row, col)
  check(label .. ': found at its position', tag and tag.name, name)
  check(label .. ': its form', tag and tag.type, form)
  check(label .. ': it has a body for its handlers', tag and (tag.body ~= nil), true)
  local all = Tag.parse_all_tags(buf)
  check(label .. ': the tag handlers see it', all and #vim.tbl_filter(function(t) return t.name == name end, all) >= 1, true)
  -- the tags that have a handler in the editor have one for the form
  local HANDLED = {
    status = true, date = true, scheduled = true, deadline = true, closed = true, fn = true, link = true, section = true,
    comment = true, hl = true, query = true, feydb = true, clocktable = true, nvim = true, plugin = true,
  }
  if HANDLED[name] then
    local handlers = Tag.handlers[name]
    check(label .. ': it has a handler', handlers ~= nil and handlers[form] ~= nil or name == 'status' and handlers ~= nil, true)
  end
  -- the ones that only draw can be run
  if all and (name == 'hl' or name == 'comment') then
    for _, t in ipairs(all) do
      if t.name == name then
        check(label .. ': its handler runs', (pcall(function() t:apply() end)), true)
        break
      end
    end
  end

  -- exported, completed
  local md_ok, md = pcall(Export.markdown, src)
  local html_ok = pcall(Export.html, src)
  check(label .. ': exports', { md_ok, html_ok }, { true, true })
  if md_ok and name ~= 'comment' then check(label .. ': the Markdown is text or nothing', type(md) == 'string' or md == nil, true) end
  check(label .. ': completion knows the name', vim.tbl_contains(data.tag_names(), name), true)
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- a tag of the table of the roadmap that has no sample here is a tag nobody tests
local covered = {}
for _, sample in ipairs(SAMPLES) do
  covered[sample[1]] = true
end
local tasks = vim.fn.readfile(vim.fn.getcwd() .. '/TASKS.fey')
local in_table, missing, rows_seen = false, {}, 0
for _, line in ipairs(tasks) do
  if line:match('^| tag%s+| format') then in_table = true end
  if in_table then
    local names = line:match('^| ([%w_, ()%-]+)%s+|')
    if names and not names:match('^tag') and not names:match('^%-') then
      rows_seen = rows_seen + 1
      for n in names:gsub('%(.-%)', ''):gmatch('[%w_]+') do
        if not covered[n] and not vim.tbl_contains({ 'exists', 'name', 'earlier' }, n) then missing[#missing + 1] = n end
      end
    end
    if in_table and not line:match('^[|+]') then in_table = false end
  end
end
table.sort(missing)
check('every tag of the table of tags has a sample', missing, {})
check('the table of tags was read', rows_seen > 20, true)

print(('tags_matrix: %d checks, %d failures'):format(total, failures))
vim.cmd(failures == 0 and 'qa!' or 'cq!')
