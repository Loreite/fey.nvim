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

---Absolute path of a link target: `~/`, absolute, `./` and `../` (relative to the file that
---holds the link) and otherwise relative to the vault root, the file's folder or the cwd
---@param target string
---@param from_path string file that holds the link
---@return string|nil
function M.resolve_path(target, from_path)
  local from_dir = vim.fs.dirname(from_path)
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

---Open a `link` tag: a URL, or a file optionally at a heading (`section:` attribute)
---@param tag FeyTag
function M.open_link(tag)
  local target = tag.values[1] and unescape(tag.values[1]) or nil
  local sig = tag.key_values.section or tag.key_values.heading
  local n = tonumber(tag.key_values.n)
  local from = from_path_of(tag)

  if target and M.is_url(target) then
    local ok, err = vim.ui.open(target)
    if not ok then vim.notify('fey: cannot open ' .. target .. (err and (': ' .. tostring(err)) or ''), vim.log.levels.WARN) end
    return ok ~= nil
  end

  if not target or target == '' then
    if sig then return M.goto_section({ signature = unescape(sig), n = n }, from) end
    return vim.notify('fey: the link tag has no target', vim.log.levels.WARN)
  end

  local path = M.resolve_path(target, from)
  if not path then return vim.notify(('fey: cannot find %s'):format(target), vim.log.levels.WARN) end
  if sig then return M.goto_section({ signature = unescape(sig), file = path, n = n }, from) end
  open_at(path)
  return true
end

---Follow the link or section tag under the cursor
---@param bufnr? integer
function M.open_at_cursor(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local node = M.tag_at_cursor(bufnr)
  if not node then return vim.notify('fey: no link under the cursor', vim.log.levels.INFO) end
  local Tag = require('fey.files.elements.tags')
  local tag = Tag.parse_tag_node(bufnr, node)
  local handlers = Tag.handlers[tag.name]
  if handlers and handlers[tag.type] then return tag:apply() end
  if link_kind(tag.name) == 'section' then return M.open_section(tag) end
  return M.open_link(tag)
end

return M
