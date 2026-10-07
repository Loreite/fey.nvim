-- Following `link` and `section` tags.
--
--   {@ link, notes/a.fey; desc: A; section: I.A. @}   a file (or URL), optionally at a heading
--   {@ section, I.A., notes/a.fey, 2 @}                a heading by signature (see fey.links.section)
--
-- `open_at_cursor` follows the tag under the cursor; when the cursor is not inside a tag it
-- uses the first link tag at or after the cursor on the same line (which is what makes the
-- links in the cells of a query result table work).
local config = require('fey.config')
local signature = require('fey.links.signature')
local section = require('fey.links.section')

local M = {}

local TAG_TYPES = { scope_tag = true, line_tag = true, block_tag = true, pair_tag = true }

local tag_query

---@param node TSNode
---@param bufnr integer
---@return string
local function tag_name(node, bufnr)
  local head = node:type() == 'pair_tag' and node:field('open')[1] or node
  local name = head and head:field('name')[1]
  return name and vim.treesitter.get_node_text(name, bufnr) or ''
end

---@param name string
---@return 'link'|'section'|nil
local function link_kind(name)
  if name == config.fey_link_tag_name then return 'link' end
  if name == config.fey_section_tag_name then return 'section' end
end

---@param s string
local function unescape(s) return (s:gsub('\\(.)', '%1')) end

---The link or section tag at the cursor, see the module description
---@param bufnr? integer
---@return TSNode|nil
function M.tag_at_cursor(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row, col = cursor[1] - 1, cursor[2]
  local root = vim.treesitter.get_parser(bufnr, 'fey', {}):parse()[1]:root()

  local node = root:named_descendant_for_range(row, col, row, col)
  while node do
    if TAG_TYPES[node:type()] and link_kind(tag_name(node, bufnr)) then return node end
    node = node:parent()
  end

  tag_query = tag_query or vim.treesitter.query.parse('fey', '[(scope_tag) (pair_tag) (line_tag) (block_tag)] @tag')
  local best, best_col
  for _, n in tag_query:iter_captures(root, bufnr, row, row + 1) do
    if link_kind(tag_name(n, bufnr)) then
      local sr, sc = n:start()
      if sr == row and (not best or (best_col < col and sc >= col) or (sc >= col and sc < best_col)) then
        best, best_col = n, sc
      end
    end
  end
  return best
end

-- Paths -------------------------------------------------------------------------------------------

---@param target string
function M.is_url(target) return target:match('^%a[%w+.-]*://') ~= nil or target:match('^mailto:') ~= nil end

---@param path string
---@return string|nil
local function existing(path)
  for _, candidate in ipairs({ path, path .. '.fey' }) do
    local stat = vim.uv.fs_stat(candidate)
    if stat and stat.type == 'file' then return vim.fs.normalize(candidate) end
  end
end

---Absolute path of a link target: a hollow reference (`court:notes/a.fey`), `~/`, absolute, `./` and `../`
---(relative to the file that holds the link) and otherwise relative to the vault root, the file's folder
---or the cwd
---@param target string
---@param from_path string file that holds the link
---@return string|nil
function M.resolve_path(target, from_path)
  local from_dir = vim.fs.dirname(from_path)

  -- a file of another hollow: `court:notes:history/a.fey`, `current:sub/b.fey`
  local tree = require('fey.hollow.tree')
  local ref = tree.parse_ref(target)
  if ref then
    local root, path = tree.resolve_ref(ref, tree.hollow_root_of(from_path))
    if not root or not path then return nil end
    return existing(vim.fs.joinpath(root, path))
  end

  if target:match('^~') then return existing(vim.fn.expand(target)) end
  if target:sub(1, 1) == '/' then return existing(target) end
  if target:match('^%.%.?/') then return existing(vim.fs.joinpath(from_dir, target)) end

  local fey_vault = require('fey.vault')
  local vault = fey_vault.for_path(from_path) or fey_vault.current()
  local bases = {}
  if vault then bases[#bases + 1] = vault.root end
  bases[#bases + 1] = from_dir
  bases[#bases + 1] = vim.fn.getcwd()
  for _, base in ipairs(bases) do
    local found = existing(vim.fs.joinpath(base, target))
    if found then return found end
  end
end

-- Headings ------------------------------------------------------------------------------------------

---Heading signatures and lines of a file, from its buffer when loaded
---@param path string
---@return { signature: string, line: integer }[]|nil
function M.headings_of(path)
  local bufnr = vim.fn.bufnr(path)
  local src
  if bufnr > 0 and vim.api.nvim_buf_is_loaded(bufnr) then
    src = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
  else
    local fh = io.open(path, 'rb')
    if not fh then return nil end
    src = fh:read('*a')
    fh:close()
  end
  local root = vim.treesitter.get_string_parser(src, 'fey'):parse()[1]:root()
  local out = {}
  local function walk(owner)
    for _, sec in ipairs(owner:field('subsection')) do
      local heading = sec:field('heading')[1]
      local sig = heading and heading:field('signature')[1]
      if sig then out[#out + 1] = { signature = vim.trim(vim.treesitter.get_node_text(sig, src)), line = sec:start() + 1 } end
      walk(sec)
    end
  end
  walk(root)
  return out
end

---@param path string absolute
---@param line? integer
local function open_at(path, line)
  local current = vim.api.nvim_buf_get_name(0)
  if vim.fn.resolve(vim.fn.fnamemodify(current, ':p')) ~= vim.fn.resolve(path) then
    vim.cmd('edit ' .. vim.fn.fnameescape(path))
  end
  if line then
    pcall(vim.api.nvim_win_set_cursor, 0, { line, 0 })
    vim.cmd('normal! zvzz')
  end
end

---Jump to a heading by signature
---@param ref { signature: string, file?: string, n?: integer }
---@param from_path string file that holds the tag
---@return boolean
function M.goto_section(ref, from_path)
  local path = from_path
  if ref.file then
    path = M.resolve_path(ref.file, from_path)
    if not path then
      vim.notify(('fey: cannot find %s'):format(ref.file), vim.log.levels.WARN)
      return false
    end
  end
  local headings = M.headings_of(path)
  if not headings then
    vim.notify(('fey: cannot read %s'):format(path), vim.log.levels.WARN)
    return false
  end
  local signatures = vim.tbl_map(function(h) return h.signature end, headings)
  local found = section.matches(signatures, ref.signature)
  if #found == 0 then
    vim.notify(('fey: no heading with signature %s in %s'):format(ref.signature, vim.fn.fnamemodify(path, ':t')), vim.log.levels.WARN)
    return false
  end
  local key = path .. '\0' .. signature.key(ref.signature)
  local position = section.next_position(key, #found, ref.n)
  open_at(path, headings[found[position]].line)
  return true
end

-- Tags -------------------------------------------------------------------------------------------------

---@param tag FeyTag
---@return string from_path
local function from_path_of(tag)
  local name = vim.api.nvim_buf_get_name(tag.bufnr)
  return vim.fn.fnamemodify(name, ':p')
end

---Open a `section` tag
---@param tag FeyTag
function M.open_section(tag)
  local ref = section.read(tag.node, tag.bufnr)
  if not ref then return vim.notify('fey: the section tag needs a signature', vim.log.levels.WARN) end
  return M.goto_section(ref, from_path_of(tag))
end

---Jump to what an id names: a heading with the prop `id`, or a file with the data key `id`, in this hollow or any open one
---@param id string
---@param from_path string file that holds the link
---@return boolean
function M.goto_id(id, from_path)
  local fey_vault = require('fey.vault')
  local first = fey_vault.for_path(from_path) or fey_vault.current()
  local vaults = first and { first } or {}
  for _, v in pairs(fey_vault.all()) do
    if v ~= first then vaults[#vaults + 1] = v end
  end
  for _, vault in ipairs(vaults) do
    local hit = vault.db and vault:find_id(id)
    if hit then
      open_at(vault:abs(hit.path), hit.line)
      return true
    end
  end
  vim.notify(('fey: no heading or file has the id %s'):format(id), vim.log.levels.WARN)
  return false
end

---Open a link: a URL, an `id:` target, a target of a scheme of `fey_link_schemes`, a hollow, or a file optionally at a heading
---@param target string|nil
---@param sig string|nil signature of a heading
---@param n integer|nil which of the headings with that signature
---@param from string file that holds the link
---@param tag? FeyTag handed to the handler of a scheme
---@return boolean|nil
function M.open_target(target, sig, n, from, tag)
  if target and M.is_url(target) then
    local ok, err = vim.ui.open(target)
    if not ok then vim.notify('fey: cannot open ' .. target .. (err and (': ' .. tostring(err)) or ''), vim.log.levels.WARN) end
    return ok ~= nil
  end

  if not target or target == '' then
    if sig then return M.goto_section({ signature = unescape(sig), n = n }, from) end
    return vim.notify('fey: the link tag has no target', vim.log.levels.WARN)
  end

  -- `id:` names a heading or a file by its id, `jira:` and the like are the schemes of the setup
  local scheme = target:match('^(%a[%w+.-]*):')
  if scheme == 'id' then return M.goto_id(target:sub(4), from) end
  local handler = scheme and (config.fey_link_schemes or {})[scheme]
  if handler then return handler(target:sub(#scheme + 2), tag) ~= false end

  -- a hollow and no file: go to the hollow
  local tree = require('fey.hollow.tree')
  local ref = tree.parse_ref(target)
  if ref and not ref.path then
    local root, _, err = tree.resolve_ref(ref, tree.hollow_root_of(from))
    if not root then return vim.notify('fey: ' .. tostring(err), vim.log.levels.WARN) end
    return require('fey.hollow.court').jump(tree.id_of(root) or root)
  end

  local path = M.resolve_path(target, from)
  if not path then return vim.notify(('fey: cannot find %s'):format(target), vim.log.levels.WARN) end
  if sig then return M.goto_section({ signature = unescape(sig), file = path, n = n }, from) end
  open_at(path)
  return true
end

---Open a `link` tag
---@param tag FeyTag
function M.open_link(tag)
  local target = tag.values[1] and unescape(tag.values[1]) or nil
  return M.open_target(target, tag.key_values.section or tag.key_values.heading, tonumber(tag.key_values.n), from_path_of(tag), tag)
end

---The first link or section tag of a text (the heading of an agenda item), as the target, signature and number it leads to
---@param text string
---@return { target?: string, sig?: string, n?: integer }|nil
function M.first_link_in(text)
  local ok, parser = pcall(vim.treesitter.get_string_parser, text, 'fey')
  if not ok then return nil end
  tag_query = tag_query or vim.treesitter.query.parse('fey', '[(scope_tag) (pair_tag) (line_tag) (block_tag)] @tag')
  local root = parser:parse()[1]:root()
  for _, node in tag_query:iter_captures(root, text) do
    local kind = link_kind(vim.trim((function()
      local head = node:type() == 'pair_tag' and node:field('open')[1] or node
      local name = head and head:field('name')[1]
      return name and vim.treesitter.get_node_text(name, text) or ''
    end)()))
    if kind then
      local head = node:type() == 'pair_tag' and node:field('open')[1] or node
      local values, keys = {}, {}
      for _, v in ipairs(head:field('value')) do
        values[#values + 1] = vim.trim(vim.treesitter.get_node_text(v, text))
      end
      for _, kv in ipairs(head:field('key_value')) do
        local k, v = kv:field('key')[1], kv:field('value')[1]
        if k and v then keys[vim.trim(vim.treesitter.get_node_text(k, text))] = vim.trim(vim.treesitter.get_node_text(v, text)) end
      end
      if kind == 'section' then return { sig = values[1] and unescape(values[1]), target = values[2] and unescape(values[2]) } end
      return {
        target = values[1] and unescape(values[1]),
        sig = keys.section or keys.heading,
        n = tonumber(keys.n),
      }
    end
  end
end

---A bare URL under the cursor (text that is not in a tag)
---@return string|nil
function M.url_at_cursor()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1
  local from = 1
  while true do
    local s, e = line:find('%a[%w+.-]*://[^%s<>%[%]{}"\']+', from)
    if not s then return nil end
    if col >= s and col <= e then return (line:sub(s, e):gsub('[.,;:!?]+$', '')) end
    from = e + 1
  end
end

---Follow the link or section tag under the cursor
---@param bufnr? integer
function M.open_at_cursor(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local node = M.tag_at_cursor(bufnr)
  if not node then
    -- not a link: a tag with an open-at-point handler (a date opens the calendar, a todo keyword cycles)
    local tag = require('fey.files.elements.tags.edit').at_cursor(bufnr)
    local Tag = require('fey.files.elements.tags')
    if tag and Tag.at_point[tag.name] and Tag.handlers[tag.name] and Tag.handlers[tag.name][tag.type] then
      return tag:apply()
    end
    local url = M.url_at_cursor()
    if url then
      local ok = vim.ui.open(url)
      return ok ~= nil
    end
    return vim.notify('fey: no link under the cursor', vim.log.levels.INFO)
  end
  local Tag = require('fey.files.elements.tags')
  local tag = Tag.parse_tag_node(bufnr, node)
  local handlers = Tag.handlers[tag.name]
  if handlers and handlers[tag.type] then return tag:apply() end
  if link_kind(tag.name) == 'section' then return M.open_section(tag) end
  return M.open_link(tag)
end

return M
