-- Embeds: a link whose target is shown where it is written.
--
--   {@ embed, photo.png; desc: a photo; width: 40 @}        an image
--   {@ embed, notes/build.lua; lines: 10-30 @}               the lines 10 to 30 of a text file
--   {@ embed, other.fey; heading: II.A. @}                   one section of a note
--   {@ link, photo.png; embed: true @}                       the same as the first, written with a `link` tag
--
-- The `embed` tag (`fey_embed_tag_name`) is the `link` tag with the key `embed` always true. The target is looked for in the folder of the note,
-- and a hollow path says otherwise: `current/path/in/the/hollow` (the hollow of the note), `court:other/path/in/it` (a hollow of the court).
--
-- The text of a file is drawn under the tag, as virtual lines (nothing of it is in the note), while the cursor is on the line of the tag
-- (`fey_embed_expand_on_cursor`) or after `toggle`. An image is drawn by an image plugin that reads the `images` query (`queries/fey/images.scm`),
-- as the neighbouring note plugins do: snacks.image reads it; `images()` lists the images of a buffer for any other.
local config = require('fey.config')

local M = {}

local ns = vim.api.nvim_create_namespace('fey_embed')
local marks_ns = vim.api.nvim_create_namespace('fey_embed_marks')

M.IMAGE_EXT = {
  png = true, jpg = true, jpeg = true, gif = true, bmp = true, webp = true, tiff = true, heic = true, avif = true, svg = true,
  mp4 = true, mov = true, avi = true, mkv = true, webm = true, pdf = true,
}

local MAX_BYTES = 1024 * 1024

local function unescape(s) return (s:gsub('\\(.)', '%1')) end

-- What is an embed --------------------------------------------------------------------------------------------

---Is a tag with this name and these keys an embed: the `embed` tag, or a `link` tag whose key `embed` is not false
---@param name string
---@param keys table<string, string>
---@return boolean
function M.is_embed(name, keys)
  if name == config.fey_embed_tag_name then return true end
  if name ~= config.fey_link_tag_name then return false end
  local value = keys.embed
  return value ~= nil and value:lower() ~= 'false'
end

---The target an embed (or link) tag points to
---@param values string[]
---@param keys table<string, string>
---@return string|nil
function M.target_of(values, keys)
  local raw = values[1] or keys.url or keys.file
  return raw and unescape(raw) or nil
end

---What kind of file a path is, from its extension: 'image', 'fey' or 'text' (anything else is read as text, and refused when it is not)
---@param path string
---@return 'image'|'fey'|'text'
function M.kind_of(path)
  local ext = (path:match('%.([%w]+)$') or ''):lower()
  if M.IMAGE_EXT[ext] then return 'image' end
  if ext == 'fey' or ext == 'fey_archive' then return 'fey' end
  return 'text'
end

-- Paths -------------------------------------------------------------------------------------------------------

local function is_file(path)
  local stat = vim.uv.fs_stat(path)
  return stat ~= nil and stat.type == 'file'
end

---The file an embed target names. Looked for, in this order: a hollow path (`current/a/b`, `court:other/a/b`), `~/` and absolute paths,
---the folder of the note, and last the root of the hollow of the note (the way the importers write a name).
---@param target string
---@param from_path string the note that holds the embed
---@return string|nil path absolute
function M.resolve(target, from_path)
  if not target or target == '' then return nil end
  local tree = require('fey.hollow.tree')
  local ref = tree.parse_ref(target)
  if ref then
    local root, path = tree.resolve_ref(ref, tree.hollow_root_of(from_path))
    if not root or not path then return nil end
    local file = vim.fs.joinpath(root, path)
    return is_file(file) and vim.fs.normalize(file) or nil
  end
  if target:match('^~') then
    local file = vim.fn.expand(target)
    return is_file(file) and vim.fs.normalize(file) or nil
  end
  if target:sub(1, 1) == '/' then return is_file(target) and vim.fs.normalize(target) or nil end
  local decoded = target:gsub('%%(%x%x)', function(hex) return string.char(tonumber(hex, 16)) end)
  local bases = { vim.fs.dirname(from_path) }
  local root = tree.hollow_root_of(from_path)
  if root then bases[#bases + 1] = root end
  for _, base in ipairs(bases) do
    for _, candidate in ipairs({ target, decoded }) do
      local file = vim.fs.joinpath(base, candidate)
      if is_file(file) then return vim.fs.normalize(file) end
    end
  end
end

-- Content -----------------------------------------------------------------------------------------------------

---@type table<string, { mtime: integer, size: integer, lines: string[] }>
local cache = {}

---The lines of a text file, cached by its modification time
---@param path string
---@return string[]|nil lines
---@return string|nil err
local function file_lines(path)
  local stat = vim.uv.fs_stat(path)
  if not stat then return nil, 'cannot find the file' end
  if stat.size > MAX_BYTES then return nil, 'the file is too big to show' end
  local hit = cache[path]
  if hit and hit.mtime == stat.mtime.sec and hit.size == stat.size then return hit.lines end
  local fh = io.open(path, 'rb')
  if not fh then return nil, 'cannot read the file' end
  local data = fh:read('*a')
  fh:close()
  if data:find('\0', 1, true) then return nil, 'the file is not text' end
  local text = data:gsub('\r\n', '\n'):gsub('\n$', '')
  local lines = vim.split(text, '\n', { plain = true })
  cache[path] = { mtime = stat.mtime.sec, size = stat.size, lines = lines }
  return lines
end

---`10-30`, `10-` (to the end), `-30` (from the start) or `12` (one line) as the first and the last line
---@param spec string
---@param count integer
---@return integer first
---@return integer last
local function range_of(spec, count)
  local a, b = spec:match('^%s*(%d*)%s*%-%s*(%d*)%s*$')
  if not a then
    local one = tonumber(spec:match('^%s*(%d+)%s*$'))
    return one or 1, one or count
  end
  return tonumber(a) or 1, tonumber(b) or count
end

---The lines of the section of a note that has a signature
---@param lines string[]
---@param sig string
---@return integer|nil first
---@return integer|nil last
local function section_range(lines, sig)
  local src = table.concat(lines, '\n') .. '\n'
  local ok, parser = pcall(vim.treesitter.get_string_parser, src, 'fey')
  if not ok then return nil end
  local root = parser:parse()[1]:root()
  local found = {}
  local function walk(owner)
    for _, sec in ipairs(owner:field('subsection')) do
      local heading = sec:field('heading')[1]
      local node = heading and heading:field('signature')[1]
      if node then
        local sr, _, er = sec:range()
        found[#found + 1] = { signature = vim.trim(vim.treesitter.get_node_text(node, src)), first = sr + 1, last = er }
      end
      walk(sec)
    end
  end
  walk(root)
  local signatures = vim.tbl_map(function(h) return h.signature end, found)
  local hit = require('fey.links.section').matches(signatures, unescape(sig))[1]
  if not hit then return nil end
  return found[hit].first, found[hit].last
end

---What an embed shows of a file: the lines it asks for (`lines`, `heading`), at most `fey_embed_max_lines`
---@param path string
---@param keys table<string, string> the keys of the tag
---@param all? boolean every line it asks for, not only `fey_embed_max_lines`
---@return string[]|nil lines
---@return string|nil err
---@return integer|nil first the number of the first line shown
function M.content(path, keys, all)
  local lines, err = file_lines(path)
  if not lines then return nil, err end
  local first, last = 1, #lines
  local heading = keys.heading or keys.section
  if heading and M.kind_of(path) == 'fey' then
    first, last = section_range(lines, heading)
    if not first then return nil, 'no heading ' .. heading end
  elseif keys.lines then
    first, last = range_of(keys.lines, #lines)
  end
  first, last = math.max(first, 1), math.min(last, #lines)
  local out, limit = {}, all and math.huge or config.fey_embed_max_lines or 200
  for i = first, last do
    if #out >= limit then
      out[#out + 1] = ('… %d more lines'):format(last - i + 1)
      break
    end
    out[#out + 1] = lines[i]
  end
  return out, nil, first
end

-- Syntax colours ------------------------------------------------------------------------------------------------

---@type table<string, { mtime: integer, size: integer, rows: table<string, table[]> }>
local colour_cache = {}

---The colours of the lines `first` to `last` of a file: for each line, its pieces as `{ text, highlight group }`, from the tree-sitter
---`highlights` query of the language of the file (injected languages too). The whole file is parsed, so a slice of it is coloured in context.
---@param path string
---@param first integer
---@param last integer
---@return table[]|nil rows nil when the file has no parser
local function colours(path, first, last)
  local stat = vim.uv.fs_stat(path)
  local lines = file_lines(path)
  if not stat or not lines then return nil end
  local hit = colour_cache[path]
  if not hit or hit.mtime ~= stat.mtime.sec or hit.size ~= stat.size then
    hit = { mtime = stat.mtime.sec, size = stat.size, rows = {} }
    colour_cache[path] = hit
  end
  local key = first .. ':' .. last
  if hit.rows[key] ~= nil then return hit.rows[key] or nil end

  local ok, result = pcall(function()
    local ft = vim.filetype.match({ filename = path })
    local lang = ft and vim.treesitter.language.get_lang(ft)
    if not lang or not vim.treesitter.language.add(lang) then return nil end
    local text = table.concat(lines, '\n')
    local tree = vim.treesitter.get_string_parser(text, lang)
    tree:parse(true)
    -- the colour of each byte of the lines: the capture with the highest priority, the later one among equals
    local hl, pr = {}, {}
    for r = first, last do
      hl[r], pr[r] = {}, {}
    end
    tree:for_each_tree(function(tstree, ltree)
      local tlang = ltree:lang()
      local query = vim.treesitter.query.get(tlang, 'highlights')
      if not query then return end
      for id, node, meta in query:iter_captures(tstree:root(), text, first - 1, last) do
        local name = query.captures[id]
        if name:sub(1, 1) ~= '_' and name ~= 'spell' and name ~= 'nospell' then
          local group = '@' .. name .. '.' .. tlang
          local priority = tonumber(meta.priority or (meta[id] or {}).priority) or 100
          local range = vim.treesitter.get_range(node, text, meta[id])
          local sr, sc, er, ec = range[1], range[2], range[4], range[5]
          for r = math.max(sr + 1, first), math.min(er + 1, last) do
            local line = lines[r]
            local from = (r == sr + 1) and sc or 0
            local to = (r == er + 1) and ec or #line
            for b = from + 1, to do
              if (pr[r][b] or -1) <= priority then
                hl[r][b], pr[r][b] = group, priority
              end
            end
          end
        end
      end
    end)
    local rows = {}
    for r = first, last do
      local line, pieces, start = lines[r], {}, 1
      local function push(a, b, group)
        if b >= a then pieces[#pieces + 1] = { (line:sub(a, b):gsub('\t', '    ')), group or 'FeyEmbedText' } end
      end
      for b = 2, #line + 1 do
        if hl[r][b] ~= hl[r][b - 1] or b == #line + 1 then
          push(start, b - 1, hl[r][start])
          start = b
        end
      end
      rows[#rows + 1] = pieces
    end
    return rows
  end)
  hit.rows[key] = ok and result or false
  return ok and result or nil
end

-- The embeds of a buffer ----------------------------------------------------------------------------------------

---@class FeyEmbed
---@field tag FeyTag
---@field row integer first row of the tag
---@field col integer its column
---@field ecol integer the column its tag ends at
---@field last integer last row of the tag
---@field target string|nil
---@field path string|nil the file, when it is found
---@field kind 'image'|'fey'|'text'|nil
---@field drawn? integer the extmark with its text
---@field height? integer the lines drawn under the tag
---@field total? integer the lines of the file it shows

---@param bufnr integer
---@param tags FeyTag[]
---@return FeyEmbed[]
local function embeds_of(bufnr, tags)
  local from = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ':p')
  local out = {}
  for _, tag in ipairs(tags) do
    if M.is_embed(tag.name, tag.key_values) then
      local sr, sc, er, ec = tag.node:range()
      local target = M.target_of(tag.values, tag.key_values)
      local path = target and M.resolve(target, from)
      out[#out + 1] = { tag = tag, row = sr, col = sc, last = er, ecol = ec, target = target, path = path, kind = target and M.kind_of(path or target) or nil }
    end
  end
  return out
end

---The images of a buffer that are shown now, for a plugin that draws them: the row and column of the tag, the file, and the keys `width` and `height`
---@param bufnr? integer
---@return { row: integer, col: integer, path: string, desc?: string, width?: integer, height?: integer }[]
function M.images(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local tags = require('fey.files.elements.tags').parse_all_tags(bufnr)
  local out = {}
  for _, e in ipairs(tags and embeds_of(bufnr, tags) or {}) do
    if e.kind == 'image' and e.path and M.image_shown(bufnr, e.tag.node) then
      local _, col = e.tag.node:range()
      local keys = e.tag.key_values
      out[#out + 1] = {
        row = e.row + 1, col = col, path = e.path,
        desc = keys.desc and unescape(keys.desc) or nil, width = tonumber(keys.width), height = tonumber(keys.height),
      }
    end
  end
  return out
end

-- Drawing -----------------------------------------------------------------------------------------------------

---@type table<integer, FeyEmbed[]>
local state = {}
local timers = {}

---The mark of an embed that was toggled: at the start of its tag
local function toggled(bufnr, embed)
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, marks_ns, { embed.row, embed.col }, { embed.row, embed.col }, {})) do
    return mark[1]
  end
end

local function cursor_inside(bufnr, embed)
  if not config.fey_embed_expand_on_cursor then return false end
  local wins = vim.fn.win_findbuf(bufnr)
  if #wins == 0 and bufnr == vim.api.nvim_get_current_buf() then wins = { 0 } end
  for _, win in ipairs(wins) do
    local row = vim.api.nvim_win_get_cursor(win)[1] - 1
    if row >= embed.row and row <= embed.last then return true end
  end
  return false
end

---Are the embeds of a kind shown by default in this buffer: the buffer variable (set by the toggles), else the option
---@param bufnr integer
---@param images boolean images, or the text of files
---@return boolean
local function all_shown(bufnr, images)
  local ok, value = pcall(vim.api.nvim_buf_get_var, bufnr, images and 'fey_embed_images' or 'fey_embed_files')
  if ok and type(value) == 'boolean' then return value end
  if images then return config.fey_embed_images_default ~= false end
  return config.fey_embed_files_default == true
end

---Is an embed shown now: the cursor is on it, or it is shown by default and not toggled, or hidden by default and toggled
---@param bufnr integer
---@param embed FeyEmbed
local function shown(bufnr, embed)
  if cursor_inside(bufnr, embed) then return true end
  return all_shown(bufnr, embed.kind == 'image') ~= (toggled(bufnr, embed) ~= nil)
end

---Does the `images` query show the image of this tag node: a plugin asks it when it looks for the images
---@param bufnr integer|string
---@param node TSNode the tag
---@return boolean
function M.image_shown(bufnr, node)
  if type(bufnr) ~= 'number' then return true end
  local sr, sc, er = node:range()
  return shown(bufnr, { kind = 'image', row = sr, col = sc, last = er })
end

---Ask the image plugin to look again at which images to draw (snacks.image looks again when a window scrolls)
---@param bufnr integer
local function refresh_images(bufnr)
  if rawget(_G, 'Snacks') and vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_exec_autocmds, 'WinScrolled', { buffer = bufnr, modeline = false })
  end
end

---Scroll positions of the embeds that are taller than their view: the first line shown, by buffer and the place of the tag
---@type table<integer, table<string, integer>>
local scrolls = {}

local function scroll_key(embed) return embed.row .. ':' .. embed.col end

---How many lines of a file an embed shows at once: `fey_embed_view_height`, and less when the window is not tall enough for them
---@return integer
local function view_height()
  local height = config.fey_embed_view_height
  if type(height) ~= 'number' or height <= 0 then return math.huge end
  return math.max(3, math.min(height, vim.api.nvim_win_get_height(0) - 3))
end

---The lines of an embed as they are drawn, all of them: `{ chunks }` each, without the border
---@param embed FeyEmbed
---@return table[] rows
local function body_of(embed)
  local rows = {}
  local function add(text, hl) rows[#rows + 1] = { { (text:gsub('\t', '    ')), hl } } end
  if not embed.path then
    add(('cannot find %s'):format(embed.target or 'the target'), 'DiagnosticWarn')
    return rows
  end
  local lines, err, first = M.content(embed.path, embed.tag.key_values)
  if not lines then
    add(err or 'cannot read the file', 'DiagnosticWarn')
    return rows
  end
  if #lines == 0 then add('no lines there', 'DiagnosticWarn') end
  -- the last line may be the note of a cut (`… 3 more lines`), which is not of the file
  local cut = #lines > 0 and lines[#lines]:sub(1, 3) == '… ' and #lines or nil
  local coloured = config.fey_embed_highlight ~= false and first and colours(embed.path, first, first + (cut or #lines + 1) - 2) or nil
  for n, line in ipairs(lines) do
    if coloured and coloured[n] and n ~= cut then
      rows[#rows + 1] = coloured[n]
    else
      add(line, 'FeyEmbedText')
    end
  end
  return rows
end

---@param bufnr integer
---@param embed FeyEmbed
local function draw_one(bufnr, embed)
  if embed.drawn then
    pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, embed.drawn)
    embed.drawn = nil
  end
  embed.height = 0
  if embed.kind == 'image' or not shown(bufnr, embed) then return end
  local body = body_of(embed)
  local view = view_height()
  local from, to = 1, #body
  embed.total = #body
  if #body > view then
    local buf_scrolls = scrolls[bufnr] or {}
    scrolls[bufnr] = buf_scrolls
    local offset = math.max(0, math.min(buf_scrolls[scroll_key(embed)] or 0, #body - view))
    buf_scrolls[scroll_key(embed)] = offset
    from, to = offset + 1, offset + view
  end
  local virt = {}
  for n = from, to do
    local chunk = { { '│ ', 'FeyEmbedBorder' } }
    vim.list_extend(chunk, body[n])
    virt[#virt + 1] = chunk
  end
  if #body > view then
    virt[#virt + 1] = { { ('╰ lines %d-%d of %d (scroll: fey_embed_scroll_down and _up, all of it: fey_embed_peek)'):format(from, to, #body), 'FeyEmbedBorder' } }
  end
  local ok, id = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, embed.last, 0, { virt_lines = virt })
  embed.drawn = ok and id or nil
  embed.height = ok and #virt or 0
end

---Scroll the window so that the text drawn under an embed can be seen: Neovim does not do it for virtual lines, and under the last line of the
---note they are below the screen
---@param bufnr integer
---@param embed FeyEmbed
local function reveal(bufnr, embed)
  if bufnr ~= vim.api.nvim_get_current_buf() or (embed.height or 0) == 0 then return end
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local need = (embed.last - row) + embed.height
  local winline, height = vim.fn.winline(), vim.api.nvim_win_get_height(0)
  local over = winline + need - height
  if over > 0 then
    local n = math.min(over, winline - 1)
    if n > 0 then vim.cmd(('exe "normal! %d\\<C-e>"'):format(n)) end
  end
end

---The row of the embedded image under the cursor, which an image plugin has to be told about when images are hidden by default
---@type table<integer, integer|false>
local image_cursor = {}
---The embed the cursor is in (the place of its tag), to scroll the window once when the cursor comes to it
---@type table<integer, string|nil>
local entered = {}

---Draw a buffer again from its tags
---@param bufnr integer
---@param tags FeyTag[]
function M.apply(bufnr, tags)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  state[bufnr] = embeds_of(bufnr, tags)
  for _, embed in ipairs(state[bufnr]) do
    draw_one(bufnr, embed)
    if embed.drawn and cursor_inside(bufnr, embed) then reveal(bufnr, embed) end
  end
end

---Draw a buffer again, after the text or an option changed
---@param bufnr integer
function M.refresh(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  local tags = require('fey.files.elements.tags').parse_all_tags(bufnr)
  if tags then M.apply(bufnr, tags) end
  refresh_images(bufnr)
end

---The cursor moved: the embeds it entered or left are drawn again
---@param bufnr integer
function M.on_cursor(bufnr)
  local on_image = false
  local inside
  for _, embed in ipairs(state[bufnr] or {}) do
    if embed.kind ~= 'image' and cursor_inside(bufnr, embed) then inside = scroll_key(embed) end
    if embed.kind == 'image' then
      if not all_shown(bufnr, true) and cursor_inside(bufnr, embed) then on_image = embed.row end
    else
      local want = shown(bufnr, embed)
      if (embed.drawn ~= nil) ~= want then
        draw_one(bufnr, embed)
      end
      -- the cursor came to an embed that was drawn already: the text under it may be below the screen
      if embed.drawn and cursor_inside(bufnr, embed) and entered[bufnr] ~= scroll_key(embed) then reveal(bufnr, embed) end
    end
  end
  -- images hidden by default are shown on the line of the cursor: the plugin looks again when the cursor comes to one or leaves one
  if (image_cursor[bufnr] or false) ~= on_image then refresh_images(bufnr) end
  image_cursor[bufnr] = on_image
  entered[bufnr] = inside
end

---The embed at the cursor: the one the cursor is inside, else the first of the line
---@param bufnr integer
---@return FeyEmbed|nil
function M.embed_at(bufnr)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row, col = cursor[1] - 1, cursor[2]
  local pick
  for _, embed in ipairs(state[bufnr] or {}) do
    if row >= embed.row and row <= embed.last then
      local inside = embed.row == embed.last and col >= embed.col and col < embed.ecol
      if inside or not pick then pick = embed end
      if inside then break end
    end
  end
  return pick
end

---Scroll the text drawn under the embed at the cursor, a half view at a time
---@param direction 1|-1 down, up
function M.scroll(direction)
  local bufnr = vim.api.nvim_get_current_buf()
  M.refresh(bufnr)
  local embed = M.embed_at(bufnr)
  if not embed or embed.kind == 'image' then return vim.notify('fey: no file embed under the cursor', vim.log.levels.INFO) end
  if not shown(bufnr, embed) then return vim.notify('fey: the embed is not shown', vim.log.levels.INFO) end
  local view = view_height()
  if (embed.total or 0) <= view then return end
  local buf_scrolls = scrolls[bufnr] or {}
  scrolls[bufnr] = buf_scrolls
  local step = math.max(1, math.floor(view / 2))
  buf_scrolls[scroll_key(embed)] = math.max(0, math.min((buf_scrolls[scroll_key(embed)] or 0) + direction * step, embed.total - view))
  draw_one(bufnr, embed)
end

---Open what an embed shows in a window of its own, to move about in it, search and select: the lines the embed asks for, all of them, in a buffer
---that cannot be changed and has the colours and the filetype of the file. `q` closes it, `<CR>` opens the file at the line. An image is opened by the system.
function M.peek()
  local bufnr = vim.api.nvim_get_current_buf()
  M.refresh(bufnr)
  local embed = M.embed_at(bufnr)
  if not embed then return vim.notify('fey: no embed under the cursor', vim.log.levels.INFO) end
  if not embed.path then return vim.notify(('fey: cannot find %s'):format(embed.target or 'the target'), vim.log.levels.WARN) end
  if embed.kind == 'image' then
    local ok, err = vim.ui.open(embed.path)
    if not ok then vim.notify('fey: cannot open ' .. embed.path .. (err and (': ' .. tostring(err)) or ''), vim.log.levels.WARN) end
    return
  end
  local lines, err, first = M.content(embed.path, embed.tag.key_values, true)
  if not lines then return vim.notify('fey: ' .. (err or 'cannot read the file'), vim.log.levels.WARN) end
  local path = embed.path
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  local name = 'embed://' .. vim.fn.fnamemodify(path, ':~')
  pcall(vim.api.nvim_buf_set_name, buf, name)
  -- a note is shown by its parser alone: its filetype would load it as a note of the hollow
  local ft = vim.filetype.match({ filename = path })
  if M.kind_of(path) == 'fey' then
    pcall(vim.treesitter.start, buf, 'fey')
  elseif ft then
    vim.bo[buf].filetype = ft
    pcall(vim.treesitter.start, buf, vim.treesitter.language.get_lang(ft))
  end
  vim.bo[buf].modifiable = false
  local height = math.max(3, math.min(#lines, math.floor(vim.o.lines * 0.5)))
  vim.cmd(('botright %dsplit'):format(height))
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.wo[win].number = true
  vim.wo[win].wrap = false
  vim.wo[win].foldenable = false
  vim.wo[win].signcolumn = 'no'
  -- the numbers are those of the file
  vim.wo[win].statuscolumn = '%=%{v:lnum + ' .. ((first or 1) - 1) .. '} '
  vim.keymap.set('n', 'q', '<Cmd>close<CR>', { buffer = buf, nowait = true, desc = 'close the embed' })
  vim.keymap.set('n', '<CR>', function()
    local line = vim.api.nvim_win_get_cursor(win)[1] + (first or 1) - 1
    vim.cmd('close')
    vim.cmd('edit ' .. vim.fn.fnameescape(path))
    pcall(vim.api.nvim_win_set_cursor, 0, { line, 0 })
  end, { buffer = buf, nowait = true, desc = 'open the file at this line' })
end

---Show the embed under the cursor, or hide it (the text of a file, or an image). With `all`: the text of every file of the note, shown or hidden
---together (the option `fey_embed_files_default` says which at first); with `images`: the same for the images
---@param scope? true|'all'|'images'
function M.toggle(scope)
  local bufnr = vim.api.nvim_get_current_buf()
  M.refresh(bufnr)
  local embeds = state[bufnr] or {}
  local function set(embed, on)
    local mark = toggled(bufnr, embed)
    if on and not mark then
      vim.api.nvim_buf_set_extmark(bufnr, marks_ns, embed.row, embed.col, { strict = false })
    elseif not on and mark then
      vim.api.nvim_buf_del_extmark(bufnr, marks_ns, mark)
    end
    draw_one(bufnr, embed)
  end
  if scope then
    local images = scope == 'images'
    local now = not all_shown(bufnr, images)
    vim.api.nvim_buf_set_var(bufnr, images and 'fey_embed_images' or 'fey_embed_files', now)
    for _, embed in ipairs(embeds) do
      if (embed.kind == 'image') == images then set(embed, false) end
    end
    if images then refresh_images(bufnr) end
    vim.notify(('fey: %s %s'):format(images and 'images' or 'file embeds', now and 'shown' or 'only on the cursor'), vim.log.levels.INFO)
    return
  end
  local pick = M.embed_at(bufnr)
  if pick then
    -- the cursor on the line shows it anyway: the toggle flips what it is without the cursor
    set(pick, toggled(bufnr, pick) == nil)
    if pick.kind == 'image' then refresh_images(bufnr) elseif shown(bufnr, pick) then reveal(bufnr, pick) end
    return
  end
  vim.notify('fey: no embed under the cursor', vim.log.levels.INFO)
end

-- Images for snacks.image -----------------------------------------------------------------------------------------

---The `resolve` option of snacks.image: the paths of the embeds, relative to the note and the hollow paths
---@param file string the note
---@param src string
---@return string|nil
function M.snacks_resolve(file, src)
  if not file:match('%.fey$') and not file:match('%.fey_archive$') then return nil end
  return M.resolve(src, file)
end

local function setup_snacks()
  local snacks = rawget(_G, 'Snacks')
  local image = snacks and snacks.image
  if image and image.config and image.config.resolve == nil then image.config.resolve = M.snacks_resolve end
end

-- Setup -----------------------------------------------------------------------------------------------------------

---Does the tag node name an embed: for the `images` query, which cannot know the name from the configuration
---@param node TSNode
---@param source integer|string
---@return boolean
function M.node_is_embed(node, source)
  local name = node:field('name')[1]
  if not name then return false end
  local keys = {}
  for _, kv in ipairs(node:field('key_value')) do
    local k, v = kv:field('key')[1], kv:field('value')[1]
    if k and v then keys[vim.trim(vim.treesitter.get_node_text(k, source))] = vim.trim(vim.treesitter.get_node_text(v, source)) end
  end
  return M.is_embed(vim.trim(vim.treesitter.get_node_text(name, source)), keys)
end

function M.setup()
  vim.api.nvim_set_hl(0, 'FeyEmbedText', { link = 'Normal', default = true })
  vim.api.nvim_set_hl(0, 'FeyEmbedBorder', { link = 'Comment', default = true })

  vim.treesitter.query.add_predicate('fey-embed-image?', function(match, _, source, predicate)
    local node = match[predicate[2]]
    node = type(node) == 'table' and node[#node] or node
    local tag = node and node:parent()
    if not tag or not M.node_is_embed(tag, source) then return false end
    if M.kind_of(unescape(vim.trim(vim.treesitter.get_node_text(node, source)))) ~= 'image' then return false end
    return M.image_shown(source, tag)
  end, { force = true, all = true })

  local group = vim.api.nvim_create_augroup('FeyEmbed', { clear = true })
  vim.api.nvim_create_autocmd({ 'FileType', 'BufEnter', 'TextChanged', 'InsertLeave' }, {
    group = group,
    pattern = { 'fey', '*.fey' },
    callback = function(args)
      setup_snacks()
      if timers[args.buf] then timers[args.buf]:stop() end
      timers[args.buf] = vim.defer_fn(function() M.refresh(args.buf) end, 100)
    end,
  })
  vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI', 'WinEnter' }, {
    group = group,
    pattern = { 'fey', '*.fey' },
    callback = function(args) M.on_cursor(args.buf) end,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    callback = function(args)
      state[args.buf] = nil
      timers[args.buf] = nil
      image_cursor[args.buf] = nil
      entered[args.buf] = nil
      scrolls[args.buf] = nil
    end,
  })
end

M.ns = ns

return M
