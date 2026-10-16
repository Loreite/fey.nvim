-- Fey variables (`var` tag).
--
-- Variables are defined with line, block, or pair `var` tags:
--   #[ var, url1 ] https://gitlab.com/rrml/webd/realm/site.git#
--   #[ var, name: url1 ] https://gitlab.com/rrml/webd/realm/site.git#
--   #[ var; name: url1 ] https://gitlab.com/rrml/webd/realm/site.git#
--
-- Scope `var` tags insert the variable text on export only:
--   {# var, url1 #}
--   {# var, name: url1 #}
--
-- Any tag can reference variables in its values and key-values with `$name$` or `$vault:path:to:var$`,
-- resolved both when the tag executes and on export.
--
-- All variables live in the vault system. Unqualified lookups search:
--   1. Current document/buffer
--   2. Current hollow's vault
--   3. Ancestor hollows' vaults (innermost to outermost)
--   4. The court vault
-- Qualified lookups (`vault:path:to:var` or `court:hollow/file.fey:var`) resolve directly in the target
-- hollow/file without walking up parent scopes.
local M = {}

local uv = vim.uv

---@class FeyVarDef
---@field name string
---@field value string
---@field line integer 1-based line number
---@field col integer 1-based column number
---@field heading_ord? integer

---@class FeyVarLocation
---@field name string
---@field value string
---@field path? string absolute file path
---@field bufnr? integer buffer number if resolved from a buffer
---@field line integer 1-based line number
---@field col? integer 1-based column number

---@class FeyVarLookupOpts
---@field bufnr? integer source buffer
---@field path? string source file path (absolute)
---@field src? string source text when resolving without a buffer
---@field vars? table<string, string> explicit local variable overrides
---@field _depth? integer internal recursion depth

local buf_cache = {}

---@return string
function M.tag_name()
  local ok, config = pcall(require, 'fey.config')
  return (ok and config and config.fey_var_tag_name) or 'var'
end

---@param node TSNode
---@param src integer|string
---@return string
local function node_text(node, src) return vim.treesitter.get_node_text(node, src) end

---@param s string
---@return string
local function unescape_sigils(s) return (s:gsub('\\([#%[%]{}])', '%1')) end

---Dedents common leading whitespace across non-empty lines and trims outer blank lines
---@param text string
---@return string
local function normalize_multiline_body(text)
  text = text:gsub('^\r?\n', ''):gsub('\r?\n[ \t]*$', '')
  local lines = vim.split(text, '\n', { plain = true })
  for i, l in ipairs(lines) do
    lines[i] = l:gsub('\r$', '')
  end
  while #lines > 0 and lines[1]:match('^%s*$') do
    table.remove(lines, 1)
  end
  while #lines > 0 and lines[#lines]:match('^%s*$') do
    table.remove(lines, #lines)
  end
  if #lines == 0 then return '' end
  if #lines == 1 then return vim.trim(lines[1]) end

  local min_indent
  for _, l in ipairs(lines) do
    if not l:match('^%s*$') then
      local lead = #(l:match('^(%s*)') or '')
      if not min_indent or lead < min_indent then min_indent = lead end
    end
  end
  if min_indent and min_indent > 0 then
    for i, l in ipairs(lines) do
      if #l >= min_indent then lines[i] = l:sub(min_indent + 1) end
    end
  end
  return table.concat(lines, '\n')
end

---Extract the variable name from a `var` tag's positional values and key-value attributes.
---Supports `#[ var, my_name ]`, `#[ var, name: my_name ]`, and `#[ var; name: my_name ]`.
---@param values? string[]
---@param attrs? table<string, string>
---@return string|nil
function M.name_of(values, attrs)
  if attrs and type(attrs.name) == 'string' then
    local n = vim.trim(attrs.name)
    if n ~= '' then return n end
  end
  if values and type(values[1]) == 'string' then
    local raw = vim.trim(values[1])
    local stripped = raw:match('^name:%s*(.+)$')
    local n = vim.trim(stripped or raw)
    if n ~= '' then return n end
  end
  if attrs then
    for k, v in pairs(attrs) do
      if k ~= 'name' and type(v) == 'string' then return vim.trim(k) .. ':' .. vim.trim(v) end
    end
  end
  return nil
end

---Extract the variable body text from a `line_tag`, `block_tag`, or `pair_tag` node.
---Returns `nil` for `scope_tag` (which is an insertion, not a definition).
---@param node TSNode
---@param src integer|string
---@return string|nil
function M.body_text(node, src)
  local ntype = node:type()
  if ntype == 'scope_tag' then return nil end

  if ntype == 'line_tag' then
    local b = node:field('body')[1]
    if not b then
      for child in node:iter_children() do
        if child:type() == 'body' then
          b = child
          break
        end
      end
    end
    if not b then return '' end
    return vim.trim(unescape_sigils(node_text(b, src)))
  end

  if ntype == 'block_tag' then
    local b = node:field('body')[1]
    if not b then
      for child in node:iter_children() do
        if child:type() == 'body' then
          b = child
          break
        end
      end
    end
    if not b then return '' end
    return normalize_multiline_body(unescape_sigils(node_text(b, src)))
  end

  if ntype == 'pair_tag' then
    local open_node = node:field('open')[1]
    local close_node = node:field('close')[1]
    if open_node and close_node then
      local _, _, open_byte = open_node:end_()
      local _, _, close_byte = close_node:start()
      if close_byte <= open_byte then return '' end
      local raw
      if type(src) == 'string' then
        raw = src:sub(open_byte + 1, close_byte)
      else
        local sr, sc = open_node:end_()
        local er, ec = close_node:start()
        local pieces = vim.api.nvim_buf_get_text(src, sr, sc, er, ec, {})
        raw = table.concat(pieces, '\n')
      end
      return normalize_multiline_body(unescape_sigils(raw))
    end
    local b = node:field('body')[1]
    if not b then return '' end
    return normalize_multiline_body(unescape_sigils(node_text(b, src)))
  end

  return nil
end

---Read raw tag name, values, and key_values from a tag node or pair_tag_open node
---@param target TSNode
---@param src integer|string
---@return string|nil name
---@return string[] values
---@return table<string, string> attrs
local function read_raw_head(target, src)
  local name_node = target:field('name')[1]
  if not name_node then return nil, {}, {} end
  local name = vim.trim(node_text(name_node, src))
  local values, attrs = {}, {}
  for _, v in ipairs(target:field('value')) do
    local val = vim.trim(unescape_sigils(node_text(v, src)))
    if val ~= '' then values[#values + 1] = val end
  end
  for _, kv in ipairs(target:field('key_value')) do
    local k = kv:field('key')[1]
    local v = kv:field('value')[1]
    if k and v then
      local key = vim.trim(node_text(k, src))
      local val = vim.trim(unescape_sigils(node_text(v, src)))
      if key ~= '' then attrs[key] = val end
    end
  end
  return name, values, attrs
end

---Extract all `var` definitions from a parsed tree-sitter root node.
---@param root TSNode
---@param src integer|string
---@return FeyVarDef[] defs
---@return table<string, string> map
function M.extract_from_tree(root, src)
  local defs = {}
  local map = {}
  local var_tag = M.tag_name()

  local function visit(node)
    local ntype = node:type()
    if ntype == 'line_tag' or ntype == 'block_tag' or ntype == 'pair_tag' then
      local head = ntype == 'pair_tag' and node:field('open')[1] or node
      if head then
        local tname, values, attrs = read_raw_head(head, src)
        if tname == var_tag then
          local vname = M.name_of(values, attrs)
          local body = vname and M.body_text(node, src) or nil
          if vname and body ~= nil then
            local sr, sc = node:range()
            defs[#defs + 1] = {
              name = vname,
              value = body,
              line = sr + 1,
              col = sc + 1,
            }
            map[vname] = body
          end
        end
      end
    end
    for child in node:iter_children() do
      visit(child)
    end
  end

  visit(root)
  return defs, map
end

---Extract variable definitions from raw Fey source text.
---@param src string
---@return FeyVarDef[] defs
---@return table<string, string> map
function M.extract_from_string(src)
  if type(src) ~= 'string' or src == '' then return {}, {} end
  if not pcall(vim.treesitter.language.add, 'fey') then return {}, {} end
  local ok, parser = pcall(vim.treesitter.get_string_parser, src, 'fey')
  if not ok or not parser then return {}, {} end
  local trees = parser:parse()
  if not trees or not trees[1] then return {}, {} end
  return M.extract_from_tree(trees[1]:root(), src)
end

---Return variable definitions and name->value map for a loaded buffer, cached by changedtick.
---@param bufnr? integer
---@return FeyVarDef[] defs
---@return table<string, string> map
function M.buffer_defs(bufnr)
  bufnr = (bufnr and bufnr ~= 0) and bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then return {}, {} end
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local cached = buf_cache[bufnr]
  if cached and cached.tick == tick then return cached.defs, cached.map end

  if not pcall(vim.treesitter.language.add, 'fey') then return {}, {} end
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, 'fey')
  if not ok or not parser then return {}, {} end
  local ok_parse, trees = pcall(parser.parse, parser)
  if not ok_parse or not trees or not trees[1] then return {}, {} end
  local defs, map = M.extract_from_tree(trees[1]:root(), bufnr)
  buf_cache[bufnr] = { tick = tick, defs = defs, map = map }
  return defs, map
end

---@param bufnr? integer
---@return table<string, string>
function M.buffer_vars(bufnr)
  local _, map = M.buffer_defs(bufnr)
  return map
end

---@param path string
---@return string
local function realpath(path) return uv.fs_realpath(path) or vim.fs.normalize(path) end

---Find a loaded buffer for an absolute path, if any
---@param abs_path string
---@return integer|nil
local function find_loaded_buf(abs_path)
  local target = realpath(abs_path)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then
      local bname = vim.api.nvim_buf_get_name(b)
      if bname ~= '' and realpath(bname) == target then return b end
    end
  end
  return nil
end

---Ensure a hollow's vault is opened and has indexed any unindexed/modified files on disk.
---@param root string
---@param force_sync? boolean
---@return FeyVault|nil
local function get_vault(root, force_sync)
  local vault_mod = require('fey.vault')
  local vault = vault_mod.for_path(root)
  if not vault or realpath(vault.root) ~= realpath(root) then vault = vault_mod.open(root) end
  if not vault then return nil end
  if not vault:open() then return nil end
  if vault.state == 'idle' or force_sync then vault:sync() end
  return vault
end

---Look up a variable inside a single hollow root, optionally restricted to `rel_path`.
---@param root string
---@param var_name string
---@param rel_path? string
---@param prefer_rel? string
---@return FeyVarLocation|nil
local function lookup_in_hollow(root, var_name, rel_path, prefer_rel)
  root = realpath(root)

  -- Normalize candidate relative file paths when `rel_path` is specified
  local candidates
  if rel_path and rel_path ~= '' then
    local clean = rel_path:gsub('^%./', '')
    candidates = { clean }
    if not clean:match('%.fey$') and not clean:match('%.fey_archive$') then candidates[#candidates + 1] = clean .. '.fey' end
    -- Check if the target file is open in a buffer first
    for _, cand in ipairs(candidates) do
      local abs = vim.fs.joinpath(root, cand)
      local b = find_loaded_buf(abs)
      if b then
        local defs, map = M.buffer_defs(b)
        if map[var_name] ~= nil then
          local line, col = 1, 1
          for i = #defs, 1, -1 do
            if defs[i].name == var_name then
              line, col = defs[i].line, defs[i].col
              break
            end
          end
          return { name = var_name, value = map[var_name], path = abs, bufnr = b, line = line, col = col }
        end
      end
    end
  else
    -- Check any modified loaded buffers inside this hollow root
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].modified then
        local bname = vim.api.nvim_buf_get_name(b)
        if bname ~= '' then
          local rpath = realpath(bname)
          local vault = get_vault(root, false)
          local rel = vault and vault:rel_of(rpath) or nil
          if rel then
            local defs, map = M.buffer_defs(b)
            if map[var_name] ~= nil then
              local line, col = 1, 1
              for i = #defs, 1, -1 do
                if defs[i].name == var_name then
                  line, col = defs[i].line, defs[i].col
                  break
                end
              end
              return { name = var_name, value = map[var_name], path = rpath, bufnr = b, line = line, col = col }
            end
          end
        end
      end
    end
  end

  local vault = get_vault(root, false)
  if not vault then return nil end

  local function query_vault()
    if candidates then
      for _, cand in ipairs(candidates) do
        local rows = vault:vars({ name = var_name, path = cand })
        if #rows > 0 then
          local hit = rows[#rows]
          return {
            name = var_name,
            value = hit.value,
            path = vim.fs.joinpath(vault.root, hit.path),
            line = hit.line or 1,
          }
        end
      end
      return nil
    end

    local rows = vault:vars({ name = var_name })
    if #rows == 0 then return nil end
    if prefer_rel then
      for i = #rows, 1, -1 do
        if rows[i].path == prefer_rel then
          return {
            name = var_name,
            value = rows[i].value,
            path = vim.fs.joinpath(vault.root, rows[i].path),
            line = rows[i].line or 1,
          }
        end
      end
    end
    local hit = rows[1]
    return {
      name = var_name,
      value = hit.value,
      path = vim.fs.joinpath(vault.root, hit.path),
      line = hit.line or 1,
    }
  end

  local hit = query_vault()
  if hit then return hit end

  -- If not found in the cached index, sync any new/modified files on disk and retry once
  if vault:sync() then return query_vault() end
  return nil
end

---Find a registered child hollow by name in `registry_root`
---@param registry_root? string
---@param name string
---@return string|nil child_root
local function find_child_hollow(registry_root, name)
  if not registry_root then return nil end
  local tree = require('fey.hollow.tree')
  for _, entry in ipairs(tree.entries(registry_root)) do
    if entry.name == name and entry.ok then return tree.realpath(entry.root) end
  end
  return nil
end

---Resolve a qualified reference (`vault:path:to:var`, `court:notes/file.fey:var`, `dir/file:var`, etc.)
---@param ref string
---@param from_root? string
---@return FeyVarLocation|nil
local function resolve_qualified(ref, from_root)
  local tree = require('fey.hollow.tree')
  local court = require('fey.hollow.court')
  local court_root = court.root()

  -- Case 1: Contains `/` (e.g. `court:notes/dir/file.fey:var`, `court:notes/var`, `dir/file.fey:var`)
  local slash = ref:find('/', 1, true)
  if slash then
    local colon_after_slash = ref:find(':', slash + 1, true)
    if colon_after_slash then
      -- Split at the last `:` after `/`
      local last_colon = colon_after_slash
      while true do
        local nxt = ref:find(':', last_colon + 1, true)
        if not nxt then break end
        last_colon = nxt
      end
      local target_part = ref:sub(1, last_colon - 1)
      local var_name = ref:sub(last_colon + 1)
      if var_name == '' then return nil end

      if tree.parse_ref(target_part) then
        local root, rel_path = tree.resolve_ref(target_part, from_root)
        if root then return lookup_in_hollow(root, var_name, rel_path) end
        return nil
      elseif target_part:find(':', 1, true) then
        -- Try resolving relative to `from_root` (`current:...`) or `court` (`court:...`)
        if from_root then
          local root, rel_path = tree.resolve_ref('current:' .. target_part, from_root)
          if root then return lookup_in_hollow(root, var_name, rel_path) end
        end
        if court_root then
          local root, rel_path = tree.resolve_ref('court:' .. target_part, from_root)
          if root then return lookup_in_hollow(root, var_name, rel_path) end
        end
        return nil
      else
        -- Relative file path in `from_root`
        if from_root then return lookup_in_hollow(from_root, var_name, target_part) end
        return nil
      end
    else
      -- `/` without trailing `:`: e.g. `court:notes/var` or `court:notes/dir/file/var`
      local last_slash = slash
      while true do
        local nxt = ref:find('/', last_slash + 1, true)
        if not nxt then break end
        last_slash = nxt
      end
      local prefix = ref:sub(1, last_slash - 1)
      local var_name = ref:sub(last_slash + 1)
      if var_name == '' then return nil end

      local root, rel_path
      if tree.parse_ref(prefix) then
        root, rel_path = tree.resolve_ref(prefix, from_root)
      elseif prefix:find(':', 1, true) then
        if from_root then
          root, rel_path = tree.resolve_ref('current:' .. prefix, from_root)
        end
        if not root and court_root then
          root, rel_path = tree.resolve_ref('court:' .. prefix, from_root)
        end
      else
        root, rel_path = from_root, prefix
      end
      if not root then return nil end
      return lookup_in_hollow(root, var_name, rel_path)
    end
  end

  -- Case 2: Pure colon-separated reference: `vault:path:to:var`
  local parts = vim.split(ref, ':', { plain = true })
  if #parts < 2 then return nil end
  local var_name = parts[#parts]
  if var_name == '' then return nil end

  local root
  local idx = 1
  if parts[1] == 'court' then
    root = court_root
    idx = 2
  elseif parts[1] == 'current' then
    root = from_root
    idx = 2
  else
    -- Check if `parts[1]` is a registered hollow in `from_root` or in `court`
    local child = find_child_hollow(from_root, parts[1]) or find_child_hollow(court_root, parts[1])
    if child then
      root = child
      idx = 2
    else
      -- Otherwise treat `parts[1..#parts-1]` as a path inside `from_root`
      root = from_root
      idx = 1
    end
  end

  if not root then return nil end

  -- Walk down registered child hollows as far as segments match
  while idx <= #parts - 1 do
    local child = find_child_hollow(root, parts[idx])
    if child then
      root = child
      idx = idx + 1
    else
      break
    end
  end

  local rel_path
  if idx <= #parts - 1 then rel_path = table.concat(parts, '/', idx, #parts - 1) end

  return lookup_in_hollow(root, var_name, rel_path)
end

---Determine the context buffer, file path, and starting hollow root from `opts`.
---@param opts? FeyVarLookupOpts
---@return integer|nil bufnr
---@return string|nil path
---@return string|nil from_root
local function resolve_context(opts)
  opts = opts or {}
  local bufnr = opts.bufnr
  if type(bufnr) == 'string' then
    opts.src = opts.src or bufnr
    bufnr = nil
  end
  if bufnr == 0 then bufnr = vim.api.nvim_get_current_buf() end
  if not bufnr and not opts.path then
    local cur = vim.api.nvim_get_current_buf()
    if vim.api.nvim_buf_is_valid(cur) then bufnr = cur end
  end

  local path = opts.path
  if (not path or path == '') and type(bufnr) == 'number' and vim.api.nvim_buf_is_valid(bufnr) then
    local bname = vim.api.nvim_buf_get_name(bufnr)
    if bname ~= '' then path = realpath(bname) end
  elseif path and path ~= '' then
    path = realpath(path)
  end

  local tree = require('fey.hollow.tree')
  local from_root = path and tree.hollow_root_of(path) or nil
  if not from_root then
    local current_vault = require('fey.vault').current()
    if current_vault then
      from_root = realpath(current_vault.root)
    else
      from_root = tree.hollow_root_of(vim.fn.getcwd())
    end
  end
  return bufnr, path, from_root
end

---Resolve a variable reference (`name` or `vault:path:to:var`) and return both its value and location.
---@param ref string
---@param opts? FeyVarLookupOpts
---@return string|nil value
---@return FeyVarLocation|nil location
function M.resolve_location(ref, opts)
  if type(ref) ~= 'string' then return nil, nil end
  ref = vim.trim(ref)
  if ref == '' then return nil, nil end
  opts = opts or {}

  local bufnr, path, from_root = resolve_context(opts)

  -- Qualified reference (`vault:path:to:var` or `path/to/file:var`)
  if ref:find(':', 1, true) or ref:find('/', 1, true) then
    local loc = resolve_qualified(ref, from_root)
    if loc then return loc.value, loc end
    return nil, nil
  end

  -- 1. Explicit `opts.vars` map (e.g. during extraction or export)
  if opts.vars and opts.vars[ref] ~= nil then
    local val = opts.vars[ref]
    return val, { name = ref, value = val, path = path, bufnr = bufnr, line = 1 }
  end

  -- 2. Raw `opts.src` string when no `opts.vars` was precomputed
  if opts.src then
    if not opts._parsed_vars then
      local defs, map = M.extract_from_string(opts.src)
      opts._parsed_defs, opts._parsed_vars = defs, map
    end
    if opts._parsed_vars[ref] ~= nil then
      local val = opts._parsed_vars[ref]
      local line, col = 1, 1
      for i = #(opts._parsed_defs or {}), 1, -1 do
        if opts._parsed_defs[i].name == ref then
          line, col = opts._parsed_defs[i].line, opts._parsed_defs[i].col
          break
        end
      end
      return val, { name = ref, value = val, path = path, line = line, col = col }
    end
  end

  -- 3. Live buffer definitions
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    local defs, map = M.buffer_defs(bufnr)
    if map[ref] ~= nil then
      local val = map[ref]
      local line, col = 1, 1
      for i = #defs, 1, -1 do
        if defs[i].name == ref then
          line, col = defs[i].line, defs[i].col
          break
        end
      end
      return val, { name = ref, value = val, path = path, bufnr = bufnr, line = line, col = col }
    end
  end

  -- 4. Walk hollow scopes from local hollow -> ancestor hollows -> court hollow
  local tree = require('fey.hollow.tree')
  local court = require('fey.hollow.court')
  local scopes = {}
  local seen = {}
  local function add_scope(r)
    if not r then return end
    r = realpath(r)
    if not seen[r] then
      seen[r] = true
      scopes[#scopes + 1] = r
    end
  end

  if from_root then
    add_scope(from_root)
    for _, anc in ipairs(tree.ancestors(from_root)) do
      add_scope(anc)
    end
  end
  add_scope(court.root())

  local prefer_rel
  if from_root and path then prefer_rel = vim.fs.relpath(from_root, path) end

  for i, scope_root in ipairs(scopes) do
    local loc = lookup_in_hollow(scope_root, ref, nil, i == 1 and prefer_rel or nil)
    if loc then return loc.value, loc end
  end

  return nil, nil
end

---Resolve a variable reference (`name` or `vault:path:to:var`) to its string value.
---@param ref string
---@param opts? FeyVarLookupOpts
---@return string|nil
function M.get(ref, opts)
  local val = M.resolve_location(ref, opts)
  return val
end

---Interpolate `$var$` (and `$vault:path:to:var$`) placeholders in a string.
---@param str string
---@param opts? FeyVarLookupOpts
---@return string
function M.interpolate(str, opts)
  if type(str) ~= 'string' or not str:find('$', 1, true) then return str end
  opts = opts or {}
  local depth = (opts._depth or 0) + 1
  if depth > 8 then return str end
  local next_opts = vim.tbl_extend('force', opts, { _depth = depth })

  -- Replace `$ref$` tokens
  local replaced_any = false
  local out = str:gsub('%$([%w_][%w_.:/%-]*)%$', function(ref)
    local val = M.get(ref, next_opts)
    if val ~= nil then
      replaced_any = true
      return val
    end
    return '$' .. ref .. '$'
  end)

  if replaced_any then
    if out:find('$', 1, true) then return M.interpolate(out, next_opts) end
    return out
  end

  -- Support bare `$var` when the entire value is a single variable token
  local bare = str:match('^%$([%a_][%w_.:/%-]*)$')
  if bare then
    local val = M.get(bare, next_opts)
    if val ~= nil then
      if val:find('$', 1, true) then return M.interpolate(val, next_opts) end
      return val
    end
  end

  return out
end

---Interpolate `$var$` placeholders across a tag's `values` list and `key_values` map.
---@param values? string[]
---@param key_values? table<string, string>
---@param opts? FeyVarLookupOpts
---@return string[] values
---@return table<string, string> key_values
function M.interpolate_tag(values, key_values, opts)
  local new_values = {}
  for i, v in ipairs(values or {}) do
    new_values[i] = M.interpolate(v, opts)
  end
  local new_kvs = {}
  for k, v in pairs(key_values or {}) do
    new_kvs[k] = M.interpolate(v, opts)
  end
  return new_values, new_kvs
end

---Return all visible variable names and their resolved values for autocompletion / inspection.
---@param opts? FeyVarLookupOpts
---@return table<string, string>
function M.all_visible(opts)
  local out = {}
  local bufnr, _, from_root = resolve_context(opts)
  local tree = require('fey.hollow.tree')
  local court = require('fey.hollow.court')

  local scopes = {}
  local seen = {}
  local function add_scope(r)
    if not r then return end
    r = realpath(r)
    if not seen[r] then
      seen[r] = true
      scopes[#scopes + 1] = r
    end
  end
  if from_root then
    add_scope(from_root)
    for _, anc in ipairs(tree.ancestors(from_root)) do
      add_scope(anc)
    end
  end
  add_scope(court.root())

  -- Apply outer-to-inner so inner scopes shadow outer scopes
  for i = #scopes, 1, -1 do
    local vault = get_vault(scopes[i], false)
    if vault then
      for _, row in ipairs(vault:vars()) do
        out[row.name] = row.value
      end
    end
  end

  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    for k, v in pairs(M.buffer_vars(bufnr)) do
      out[k] = v
    end
  end
  if opts and opts.vars then
    for k, v in pairs(opts.vars) do
      out[k] = v
    end
  end
  return out
end

return M
