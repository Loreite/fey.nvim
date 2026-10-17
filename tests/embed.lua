-- Embeds: the tag, where its target is, what it shows, the index, the images query and the export. Run from the repo root:
--
--   FEY_PARSER=/path/to/fey.so nvim --headless --clean -l tests/embed.lua
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
local E = require('fey.embed')

local root = base .. '/hollow'
vim.fn.mkdir(root .. '/.fey', 'p')
vim.fn.mkdir(root .. '/notes', 'p')
vim.fn.mkdir(root .. '/assets', 'p')
local function write(path, lines) vim.fn.writefile(lines, root .. '/' .. path) end
write('notes/code.lua', { 'one', 'two', 'three', 'four', 'five' })
write('notes/pic.png', { 'PNG' })
write('assets/shared.txt', { 'shared' })
write('notes/other.fey', { '  I. First', 'first text', '', '  II. Second', 'second text', 'more second', '  III. Third', 'third' })
write('cover.png', { 'PNG' })
do
  local fh = assert(io.open(root .. '/notes/blob.bin', 'wb'))
  fh:write('x\0y')
  fh:close()
end
local note = root .. '/notes/main.fey'

-- the tag ---------------------------------------------------------------------------------------------
check('the embed tag', E.is_embed('embed', {}), true)
check('a link with the key', E.is_embed('link', { embed = 'true' }), true)
check('a link with the key off', E.is_embed('link', { embed = 'false' }), false)
check('a plain link', E.is_embed('link', {}), false)
check('another tag', E.is_embed('prop', { embed = 'true' }), false)
check('kinds of file', { E.kind_of('a.PNG'), E.kind_of('b.fey'), E.kind_of('c.lua'), E.kind_of('d') }, { 'image', 'fey', 'text', 'text' })

-- where the target is ----------------------------------------------------------------------------------
check('the folder of the note comes first', E.resolve('code.lua', note), root .. '/notes/code.lua')
check('a path in that folder', E.resolve('../assets/shared.txt', note), root .. '/assets/shared.txt')
check('then the root of the hollow', E.resolve('cover.png', note), root .. '/cover.png')
check('a hollow path: the hollow of the note', E.resolve('current/assets/shared.txt', note), root .. '/assets/shared.txt')
check('a hollow path beats the folder', E.resolve('current/cover.png', note), root .. '/cover.png')
check('a file that is not there', E.resolve('nope.png', note), nil)
check('a hollow path that is not there', E.resolve('current/nope.png', note), nil)
check('absolute', E.resolve(root .. '/cover.png', note), root .. '/cover.png')
check('a hollow path of the court', require('fey.hollow.tree').parse_ref('court:other/a/b.png'), { keyword = 'court', names = { 'other' }, path = 'a/b.png' })
check('a hollow path below it', require('fey.hollow.tree').parse_ref('court:other:history/a.png').path, 'a.png')

-- what it shows ----------------------------------------------------------------------------------------
check('the whole file', E.content(root .. '/notes/code.lua', {}), { 'one', 'two', 'three', 'four', 'five' })
check('lines', E.content(root .. '/notes/code.lua', { lines = '2-3' }), { 'two', 'three' })
check('lines to the end', E.content(root .. '/notes/code.lua', { lines = '4-' }), { 'four', 'five' })
check('lines from the start', E.content(root .. '/notes/code.lua', { lines = '-2' }), { 'one', 'two' })
check('one line', E.content(root .. '/notes/code.lua', { lines = '3' }), { 'three' })
check('a heading of a note', E.content(root .. '/notes/other.fey', { heading = 'II.' }), { '  II. Second', 'second text', 'more second' })
local none, err = E.content(root .. '/notes/other.fey', { heading = 'IX.' })
check('a heading that is not there', { none, err }, { nil, 'no heading IX.' })
none, err = E.content(root .. '/notes/blob.bin', {})
check('a file that is not text', { none, err }, { nil, 'the file is not text' })
config.fey_embed_max_lines = 2
local cut = E.content(root .. '/notes/code.lua', {})
check('the most lines', cut, { 'one', 'two', '… 3 more lines' })
config.fey_embed_max_lines = 200

-- drawing ----------------------------------------------------------------------------------------------
write('notes/main.fey', {
  '  I. T',
  '',
  'code {@ embed, code.lua; lines: 2-3 @} and a photo {@ link, pic.png; embed: true; desc: a cat; width: 30 @}',
  '',
  '{@ embed, missing.lua @}',
})
vim.cmd('edit! ' .. vim.fn.fnameescape(note))
local buf = vim.api.nvim_get_current_buf()
local function drawn()
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, E.ns, 0, -1, { details = true })) do
    local texts = {}
    for _, line in ipairs(m[4].virt_lines) do
      texts[#texts + 1] = line[2][1]
    end
    out[#out + 1] = { m[2], texts }
  end
  return out
end
vim.api.nvim_win_set_cursor(0, { 1, 0 })
E.refresh(buf)
check('nothing is shown while the cursor is elsewhere', drawn(), {})
vim.api.nvim_win_set_cursor(0, { 3, 8 })
E.on_cursor(buf)
check('the text is shown under the line of the cursor', drawn(), { { 2, { 'two', 'three' } } })
vim.api.nvim_win_set_cursor(0, { 1, 0 })
E.on_cursor(buf)
check('and gone when the cursor leaves', drawn(), {})
config.fey_embed_expand_on_cursor = false
vim.api.nvim_win_set_cursor(0, { 3, 8 })
E.on_cursor(buf)
check('the option off: not on the cursor', drawn(), {})
E.toggle()
check('a toggle shows it', drawn(), { { 2, { 'two', 'three' } } })
vim.api.nvim_win_set_cursor(0, { 1, 0 })
E.on_cursor(buf)
check('and keeps it when the cursor leaves', drawn(), { { 2, { 'two', 'three' } } })
vim.api.nvim_win_set_cursor(0, { 3, 8 })
E.toggle()
check('a second toggle hides it', drawn(), {})
E.toggle(true)
check('all: the text, a missing file told, no text for an image', drawn(), { { 2, { 'two', 'three' } }, { 4, { 'cannot find missing.lua' } } })
E.toggle(true)
check('all again hides all', drawn(), {})
config.fey_embed_expand_on_cursor = true

-- shown by default, and the images
config.fey_embed_files_default = true
pcall(vim.api.nvim_buf_del_var, buf, 'fey_embed_files')
E.refresh(buf)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
E.on_cursor(buf)
check('files shown by default: all the text, a missing file told', drawn(), { { 2, { 'two', 'three' } }, { 4, { 'cannot find missing.lua' } } })
vim.api.nvim_win_set_cursor(0, { 3, 8 })
E.toggle()
vim.api.nvim_win_set_cursor(0, { 1, 0 })
E.on_cursor(buf)
check('and a toggle hides one', drawn(), { { 4, { 'cannot find missing.lua' } } })
E.toggle(true)
check('all: the default is flipped, what was toggled is back to it', drawn(), {})
E.toggle(true)
check('all again: shown', drawn(), { { 2, { 'two', 'three' } }, { 4, { 'cannot find missing.lua' } } })
vim.api.nvim_buf_del_var(buf, 'fey_embed_files')
config.fey_embed_files_default = false
E.refresh(buf)
check('the default off: nothing without the cursor', drawn(), {})

-- images: shown by default, hidden but on the cursor line, toggled
local function image_tag_node()
  local tags = require('fey.files.elements.tags').parse_all_tags(buf)
  for _, t in ipairs(tags) do
    if t.name == 'link' then return t.node end
  end
end
vim.api.nvim_win_set_cursor(0, { 1, 0 })
check('images are shown by default', E.image_shown(buf, image_tag_node()), true)
check('and are listed', #E.images(buf), 1)
config.fey_embed_images_default = false
check('the default off: hidden', E.image_shown(buf, image_tag_node()), false)
check('and not listed', #E.images(buf), 0)
vim.api.nvim_win_set_cursor(0, { 3, 70 })
check('hidden, shown on the cursor line', E.image_shown(buf, image_tag_node()), true)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.api.nvim_win_set_cursor(0, { 3, 70 })
E.toggle()
vim.api.nvim_win_set_cursor(0, { 1, 0 })
check('a toggle shows one image', E.image_shown(buf, image_tag_node()), true)
config.fey_embed_images_default = true
E.toggle(true)
check('files are not images', vim.b[buf].fey_embed_images, nil)
E.toggle('images')
check('the toggle for images hides them all (and clears what was toggled)', { vim.b[buf].fey_embed_images, E.image_shown(buf, image_tag_node()) }, { false, false })
vim.api.nvim_win_set_cursor(0, { 3, 70 })
E.toggle()
vim.api.nvim_win_set_cursor(0, { 1, 0 })
check('one image toggled on', E.image_shown(buf, image_tag_node()), true)
vim.api.nvim_win_set_cursor(0, { 3, 70 })
E.toggle()
vim.api.nvim_win_set_cursor(0, { 1, 0 })
check('and off again', E.image_shown(buf, image_tag_node()), false)
E.toggle('images')
check('the toggle again shows them all', E.image_shown(buf, image_tag_node()), true)
vim.api.nvim_buf_del_var(buf, 'fey_embed_images')
vim.api.nvim_buf_del_var(buf, 'fey_embed_files')
E.refresh(buf)
config.fey_embed_files_default = false

-- the images -------------------------------------------------------------------------------------------
local images = E.images(buf)
check('the images of a buffer', vim.tbl_map(function(i) return { i.row, vim.fn.fnamemodify(i.path, ':t'), i.desc, i.width } end, images), { { 3, 'pic.png', 'a cat', 30 } })

local query = vim.treesitter.query.get('fey', 'images')
check('the images query is there', query ~= nil, true)
local parser = vim.treesitter.get_parser(buf, 'fey')
local srcs = {}
for _, match in query:iter_matches(parser:parse()[1]:root(), buf, 0, -1) do
  for id, nodes in pairs(match) do
    if query.captures[id] == 'image.src' then
      nodes = type(nodes) == 'table' and nodes or { nodes }
      srcs[#srcs + 1] = vim.treesitter.get_node_text(nodes[1], buf)
    end
  end
end
check('the query finds the image, not the text file', srcs, { 'pic.png' })

local snacks = E.snacks_resolve(note, 'current/cover.png')
check('the resolver for snacks.image', snacks, root .. '/cover.png')
check('and leaves other files alone', E.snacks_resolve(root .. '/a.md', 'cover.png'), nil)

-- the index --------------------------------------------------------------------------------------------
write('notes/index.fey', {
  '  I. Embeds',
  '',
  'ok {@ embed, pic.png @} and {@ embed, current/cover.png @}',
  'text {@ embed, other.fey; heading: II. @} and a missing {@ embed, gone.png @}',
  'a bad heading {@ embed, other.fey; heading: IX. @}',
  'a link {@ link, pic.png; embed: true @}',
  'a plain link {@ link, other.fey @}',
})
local vault = require('fey.vault').open(root)
local done = false
vault:scan({}, function() done = true end)
vim.wait(5000, function() return done end, 10)
local links = vault:links('notes/index.fey')
check('the links are embeds', vim.tbl_map(function(l) return l.kind end, links), { 'embed', 'embed', 'embed', 'embed', 'embed', 'embed', 'link' })
check('the file of an embed is looked for in the folder of the note', links[1].target_file, 'notes/pic.png')
check('and a hollow path is the path', { links[2].target_ref, links[2].target_file }, { 'current', 'cover.png' })
local mine = {}
for _, b in ipairs(vault:broken_links()) do
  if b.path == 'notes/index.fey' and b.kind == 'embed' then mine[#mine + 1] = b.line .. ':' .. b.reason end
end
check('broken: a missing file and a missing heading; a file that is not a note is fine', mine, { '4:file', '5:section' })

-- the export -------------------------------------------------------------------------------------------
local Export = require('fey.export')
local src = '  I. T\n\nA photo {@ embed, img/cat.png; desc: a cat; width: 30 @} and a {@ link, pic.png; embed: true @} and {@ embed, a.lua @}.\n'
local html = Export.html(src)
check('html: an image', html:find('<img src="img/cat.png" alt="a cat" width="30">', 1, true) ~= nil, true)
check('html: the link form too', html:find('<img src="pic.png"', 1, true) ~= nil, true)
check('html: a file that is not an image stays a link', html:find('<a href="a.lua">', 1, true) ~= nil, true)
local md = Export.markdown(src)
check('markdown: an image', md:find('![a cat](img/cat.png)', 1, true) ~= nil, true)

-- completion and mappings ---------------------------------------------------------------------------
check('completion knows the keys', vim.tbl_contains(require('fey.fey.autocompletion.data').keys('embed'), 'lines'), true)

print(('embed: %d checks, %d failures'):format(total, failures))
vim.cmd(failures == 0 and 'qa!' or 'cq!')
