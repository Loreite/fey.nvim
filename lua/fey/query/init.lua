-- Query tags: Dataview/Datacore style queries over the vault index, and `feydb`
-- tags that import a database view as a table.
--
--   [ query ]#                          block tag: the body is the query
--       TABLE file.name, length(file.outlinks) AS "Links"
--       FROM #design AND "notes"
--       SORT file.mtime DESC
--
--   [ query #]                          pair tag: the body is the query
--   LIST FROM "notes"
--   [# query ]
--
--   {# query, LIST FROM #design #}      scope tag: the head is the query
--   #[ query ]  LIST FROM \#design #    line tag: write a `#` of the query as `\#`
--
-- Nothing runs on its own. The mapping (default `<prefix>qq`, all queries in the
-- buffer: `<prefix>qa`) runs the query and writes the result as a Fey table or
-- list in a `query_result` pair tag directly after the query, replacing the
-- result of the previous run:
--
--   [ query_result #]
--   | File | Links |
--   +======+=======+
--   | ...  | ...   |
--   [# query_result ]
--
-- A `feydb` tag takes the number of rows to show as its one plain value and
-- names the database (and optionally the view) in its body or in attributes:
--
--   {# feydb, 10; db: projects; view: Open #}
--   [ feydb, 10 ]#  projects > Open
--
-- and writes the table into a `feydb_result` pair tag the same way. Both kinds of
-- tags also update when a buffer first loads.
local config = require('fey.config')

local M = {}

---@param name string
---@return 'query'|'feydb'|nil
local function tag_kind(name)
  if name == config.fey_query_tag_name then return 'query' end
  if name == config.fey_db_tag_name then return 'feydb' end
end

local function result_name_for(kind)
  return kind == 'feydb' and config.fey_db_result_tag_name or config.fey_query_result_tag_name
end

local STOP_PARENTS = { body = true, document = true, section = true, listitem = true }

local tag_query

local function get_tag_query()
  tag_query = tag_query or vim.treesitter.query.parse('fey', '[(scope_tag) (pair_tag) (line_tag) (block_tag)] @tag')
  return tag_query
end

---@param bufnr integer
---@param node TSNode
local function text(bufnr, node) return vim.treesitter.get_node_text(node, bufnr) end

---@param node TSNode
---@return TSNode|nil
local function name_node(node)
  local head = node:type() == 'pair_tag' and node:field('open')[1] or node
  return head and head:field('name')[1]
end

---First line is trimmed on its own (it starts mid-line), the others lose their common indentation
---@param raw string
local function dedent(raw)
  local lines = vim.split(raw, '\n', { plain = true })
  local min
  for i = 2, #lines do
    if lines[i]:find('%S') then
      local ind = #lines[i]:match('^[ \t]*')
      min = min and math.min(min, ind) or ind
    end
  end
  local out = { (lines[1]:gsub('^%s+', '')) }
  for i = 2, #lines do
    out[i] = lines[i]:sub((min or 0) + 1)
  end
  return vim.trim(table.concat(out, '\n'))
end

---The query text a tag holds, whatever its form
---@param bufnr integer
---@param node TSNode
---@return string
function M.query_text(bufnr, node)
  local t = node:type()
  local raw = ''

  if t == 'block_tag' then
    local body = node:field('body')[1]
    raw = body and text(bufnr, body) or ''
  elseif t == 'pair_tag' then
    local open, close = node:field('open')[1], node:field('close')[1]
    if open and close then
      local sr, sc = select(1, open:end_()), select(2, open:end_())
      local er, ec = close:start()
      raw = table.concat(vim.api.nvim_buf_get_text(bufnr, sr, sc, er, ec, {}), '\n')
    end
  elseif t == 'line_tag' then
    for child in node:iter_children() do
      if child:type() == 'body' then raw = text(bufnr, child) end
    end
    local sigil = text(bufnr, node):sub(1, 1)
    raw = raw:gsub(vim.pesc('\\' .. sigil), (sigil:gsub('%%', '%%%%')))
  elseif t == 'scope_tag' then
    local name = name_node(node)
    local closures = node:field('tag_closure')
    local tag_end = closures[#closures]
    if name and tag_end then
      local sr, sc = select(1, name:end_()), select(2, name:end_())
      local er, ec = tag_end:start()
      raw = table.concat(vim.api.nvim_buf_get_text(bufnr, sr, sc, er, ec, {}), '\n')
      raw = raw:gsub('^%s*[,;]', ''):gsub('\\([,;])', '%1')
    end
  end
  return dedent(raw)
end

---The element a result is attached to: the tag itself, or the paragraph/title/table that holds it
---@param node TSNode
---@return TSNode
local function anchor_of(node)
  local a, p = node, node:parent()
  while p and not STOP_PARENTS[p:type()] do
    a, p = p, p:parent()
  end
  return a
end

---Inclusive 0-indexed row range of a node (an end at column 0 belongs to the previous row)
---@param node TSNode
---@return integer, integer
local function row_range(node)
  local sr, _, er, ec = node:range()
  if ec == 0 and er > sr then er = er - 1 end
  return sr, er
end

---@class FeyQueryEdit
---@field start integer 0-indexed first row replaced
---@field stop integer 0-indexed row after the last row replaced
---@field lines string[]

---Where a vault lives for this buffer and the page the buffer holds
---@param bufnr integer
---@return FeyVault|nil vault
---@return any this
local function context(bufnr)
  local fey_vault = require('fey.vault')
  local name = vim.api.nvim_buf_get_name(bufnr)
  local vault = (name ~= '' and fey_vault.for_path(name)) or fey_vault.current()
  if not vault then return nil end
  local this
  if name ~= '' then
    local real = vim.uv.fs_realpath(name) or name
    local rel = vim.fs.relpath(vault.root, real)
    if rel then this = require('fey.query.pages').store(vault):page(rel) end
  end
  return vault, this
end

---Lines for the result of a `feydb` tag
---@param bufnr integer
---@param node TSNode
---@param vault FeyVault
---@return string[]
local function feydb_lines(bufnr, node, vault)
  local Tag = require('fey.files.elements.tags')
  local tag = Tag.parse_tag_node(bufnr, node)
  local spec = { rows = tonumber(tag.values[1]) or 10 }
  spec.db, spec.view = tag.key_values.db, tag.key_values.view
  if not spec.db then
    local body = node:type() ~= 'scope_tag' and M.query_text(bufnr, node) or ''
    local db, view = body:match('^%s*([^>\n]-)%s*>%s*(.-)%s*$')
    spec.db = db or vim.trim(body:match('^[^\n]*') or '')
    spec.view = spec.view or view
  end
  return require('fey.db.export').table_lines(vault, spec, {
    link_tag = (vault.opts.link_tags or {})[1] or 'link',
  })
end

---Run the query held by one tag and plan the buffer edit that writes its result
---@param bufnr integer
---@param node TSNode a `query` or `feydb` tag
---@param vault FeyVault
---@param this any
---@param silent? boolean no notifications
---@return FeyQueryEdit|nil edit nil when the result is already up to date
local function plan(bufnr, node, vault, this, silent)
  local kind = tag_kind(text(bufnr, name_node(node)))
  local result_name = result_name_for(kind)

  local body
  local ok, res = pcall(function()
    if kind == 'feydb' then return feydb_lines(bufnr, node, vault) end
    local query_src = M.query_text(bufnr, node)
    if query_src == '' then error('query: the tag holds no query', 0) end
    local result = require('fey.query.engine').run(vault, query_src, { this = this })
    return require('fey.query.render').lines(result, {
      link_tag = (vault.opts.link_tags or {})[1] or 'link',
    })
  end)
  if ok then
    body = res
  else
    local msg = tostring(res):gsub('[\r\n]+', ' ')
    msg = msg:gsub('^query: ', ''):gsub('^feydb: ', '')
    if not silent then vim.notify(('fey %s: %s'):format(kind, msg), vim.log.levels.WARN) end
    body = { (kind == 'feydb' and 'feydb error: ' or 'query error: ') .. msg }
  end

  local anchor = anchor_of(node)
  local _, a_er = row_range(anchor)
  local indent = (' '):rep(select(2, anchor:start()))

  local block = { indent .. ('[ %s #]'):format(result_name) }
  for _, l in ipairs(body) do
    block[#block + 1] = l == '' and l or (indent .. l)
  end
  block[#block + 1] = indent .. ('[# %s ]'):format(result_name)

  -- replace the result of the previous run (and leave it alone when nothing changed)
  local sib = anchor:next_named_sibling()
  if sib and sib:type() == 'pair_tag' then
    local n = name_node(sib)
    if n and text(bufnr, n) == result_name then
      local s, e = row_range(sib)
      local existing = vim.api.nvim_buf_get_lines(bufnr, s, e + 1, false)
      if vim.deep_equal(existing, block) then return nil end
      return { start = s, stop = e + 1, lines = block }
    end
  end

  local lines = { '' }
  vim.list_extend(lines, block)
  local after = vim.api.nvim_buf_get_lines(bufnr, a_er + 1, a_er + 2, false)[1]
  if after and after:find('%S') then lines[#lines + 1] = '' end
  return { start = a_er + 1, stop = a_er + 1, lines = lines }
end

---All `query` and `feydb` tags, in document order
---@param bufnr integer
---@return TSNode[]
function M.query_tags(bufnr)
  local tree = vim.treesitter.get_parser(bufnr, 'fey', {}):parse()[1]
  local root = tree:root()
  local out = {}
  for _, node in get_tag_query():iter_captures(root, bufnr) do
    local n = name_node(node)
    if n and tag_kind(text(bufnr, n)) then out[#out + 1] = node end
  end
  return out
end

---@param bufnr integer
---@param edits (FeyQueryEdit|nil)[]
local function apply(bufnr, edits)
  edits = vim.tbl_filter(function(e) return e ~= nil end, edits)
  table.sort(edits, function(a, b) return a.start > b.start end) -- bottom up keeps rows valid
  for i, e in ipairs(edits) do
    if i > 1 then pcall(vim.cmd, 'undojoin') end
    vim.api.nvim_buf_set_lines(bufnr, e.start, e.stop, false, e.lines)
  end
end

---Run one query tag and write its result. Used as the tag handler of `query` tags.
---@param bufnr integer
---@param node TSNode
function M.run_tag(bufnr, node)
  local vault, this = context(bufnr)
  if not vault then
    return vim.notify('fey query: no vault (a ' .. require('fey.config').vault.dirname .. ' directory) here', vim.log.levels.WARN)
  end
  if vault.state == 'indexing' then vim.notify('fey query: the vault is still being indexed', vim.log.levels.INFO) end
  apply(bufnr, { plan(bufnr, node, vault, this) })
end

---Run the query tag under the cursor (or the one whose result the cursor is in)
---@param bufnr? integer
function M.run_at_cursor(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local best
  for _, node in ipairs(M.query_tags(bufnr)) do
    local s, e = row_range(node)
    local sib = anchor_of(node):next_named_sibling()
    if sib and sib:type() == 'pair_tag' then
      local n = name_node(sib)
      if n and text(bufnr, n) == result_name_for(tag_kind(text(bufnr, name_node(node)))) then
        local _, re = row_range(sib)
        e = math.max(e, re)
      end
    end
    if row >= s and row <= e and (not best or select(1, node:start()) >= select(1, best:start())) then best = node end
  end
  if not best then return vim.notify('fey query: no query tag at the cursor', vim.log.levels.WARN) end

  -- through the tag handler, so user overrides of `Tag.handlers.query` apply
  local Tag = require('fey.files.elements.tags')
  local tag = Tag.parse_tag_node(bufnr, best)
  if Tag.handlers[tag.name] and Tag.handlers[tag.name][tag.type] then
    tag:apply()
  else
    M.run_tag(bufnr, best)
  end
end

---Run every query and feydb tag in the buffer
---@param bufnr? integer
---@param opts? { silent?: boolean }
function M.run_all(bufnr, opts)
  opts = opts or {}
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local vault, this = context(bufnr)
  if not vault then
    if not opts.silent then vim.notify('fey query: no vault here', vim.log.levels.WARN) end
    return
  end
  local edits = {}
  local nodes = M.query_tags(bufnr)
  for _, node in ipairs(nodes) do
    edits[#edits + 1] = plan(bufnr, node, vault, this, opts.silent)
  end
  if #nodes == 0 then
    if not opts.silent then vim.notify('fey query: no query tags in this buffer', vim.log.levels.INFO) end
    return
  end
  apply(bufnr, edits)
end

-- Update when a buffer first loads ---------------------------------------------------------------

---@param bufnr integer
local function has_tags(bufnr)
  for _, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if l:find(config.fey_query_tag_name, 1, true) or l:find(config.fey_db_tag_name, 1, true) then return true end
  end
  return false
end

---@param bufnr integer
local function on_load(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then return end
  local conf = config.vault
  if not conf or not conf.enabled or conf.run_on_load == false then return end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == '' or name:find('/.fey/', 1, true) or vim.bo[bufnr].buftype ~= '' then return end
  if not has_tags(bufnr) then return end

  local fey_vault = require('fey.vault')
  local vault = fey_vault.for_path(name) or fey_vault.current()
  if vault and vault.state == 'ready' then
    return M.run_all(bufnr, { silent = true })
  end
  -- the vault is not attached or still indexing: continue when a scan finished
  if vim.b[bufnr].fey_query_load_pending then return end
  vim.b[bufnr].fey_query_load_pending = true
  vim.api.nvim_create_autocmd('User', {
    pattern = 'FeyVaultIndexed',
    once = true,
    callback = function()
      vim.b[bufnr].fey_query_load_pending = nil
      vim.schedule(function() on_load(bufnr) end)
    end,
  })
end

local setup_done = false

function M.setup()
  if setup_done then return end
  setup_done = true
  vim.api.nvim_create_autocmd('BufReadPost', {
    group = vim.api.nvim_create_augroup('fey_query_load', { clear = true }),
    pattern = { '*.fey' },
    callback = function(event) vim.schedule(function() on_load(event.buf) end) end,
  })
end

return M
