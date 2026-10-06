-- `section` tags: `{@ section, signature, file, N @}` link to a heading by its signature.
--
--   signature  required, only the tokens matter (see fey.links.signature)
--   file       optional, the current file when omitted
--   N          optional, which of the headings with that signature: the first when omitted,
--              the N-th when positive (bounded by the number of matches), counted from the end
--              when negative. 0 behaves like 1 but repeating the jump moves on to the next match.
--
-- The values may also be given as attributes (`file: x.fey; n: 2`), which is how N is given
-- without a file.
--
-- Tags follow their heading: when headings are reindexed `on_reindex` rewrites the signature
-- (and N) of every section tag that pointed at a heading whose signature changed, in the
-- reindexed file and in every other file of the vault that refers to it.
local signature = require('fey.links.signature')

local M = {}

---@param s string
local function trim(s) return (s:gsub('^%s+', ''):gsub('%s+$', '')) end

---@param s string
local function unescape(s) return (s:gsub('\\(.)', '%1')) end

---@param s string
local function escape(s) return (s:gsub('\\', '\\\\'):gsub(',', '\\,'):gsub(';', '\\;')) end

---@class FeySectionRef
---@field signature string
---@field file? string
---@field n? integer
---@field nodes { signature?: TSNode, file?: TSNode, n?: TSNode }

---Read the values of a section tag. `node` is the tag (or its head).
---@param node TSNode
---@param src string|integer text source of the tree
---@return FeySectionRef|nil
function M.read(node, src)
  local head = node:type() == 'pair_tag' and node:field('open')[1] or node
  if not head then return nil end
  local function text(n) return vim.treesitter.get_node_text(n, src) end

  local plain = {}
  for _, v in ipairs(head:field('value')) do
    plain[#plain + 1] = { node = v, text = unescape(trim(text(v))) }
  end
  local attrs = {}
  for _, kv in ipairs(head:field('key_value')) do
    local k, v = kv:field('key')[1], kv:field('value')[1]
    if k and v then attrs[trim(text(k)):lower()] = { node = v, text = unescape(trim(text(v))) } end
  end

  local ref = { nodes = {} }
  local function take(name, entry)
    if entry then ref.nodes[name] = entry.node end
    return entry and entry.text or nil
  end
  local sig_entry = attrs.signature or plain[1]
  local file_entry = attrs.file or plain[2]
  local n_entry = attrs.n or plain[3]
  -- `{# section, I.A., 2 #}`: a lone number in the file place is N
  if not attrs.file and not attrs.n and plain[2] and not plain[3] and plain[2].text:match('^%-?%d+$') then
    n_entry, file_entry = plain[2], nil
  end

  ref.signature = take('signature', sig_entry)
  if not ref.signature or ref.signature == '' then return nil end
  local file = take('file', file_entry)
  ref.file = (file and file ~= '') and file or nil
  ref.n = tonumber(take('n', n_entry))
  return ref
end

---Read a `link` tag that points at a heading through its `section:` attribute
---@param node TSNode
---@param src string|integer
---@return FeySectionRef|nil
function M.read_link(node, src)
  local head = node:type() == 'pair_tag' and node:field('open')[1] or node
  if not head then return nil end
  local function text(n) return unescape(trim(vim.treesitter.get_node_text(n, src))) end
  local ref = { nodes = {} }
  for _, kv in ipairs(head:field('key_value')) do
    local k, v = kv:field('key')[1], kv:field('value')[1]
    if k and v then
      local key = trim(vim.treesitter.get_node_text(k, src)):lower()
      if key == 'section' or key == 'heading' then
        ref.signature, ref.nodes.signature = text(v), v
      elseif key == 'n' then
        ref.n, ref.nodes.n = tonumber(text(v)), v
      end
    end
  end
  local target = head:field('value')[1]
  ref.file = target and text(target) or nil
  if not ref.signature or ref.signature == '' then return nil end
  return ref
end

---Which of `matches` (indexes into a heading list) a tag with this N points at
---@param count integer number of matches
---@param n integer|nil
---@return integer position 1-based among the matches
function M.pick(count, n)
  if n == nil or n == 0 then return 1 end
  if n > 0 then return math.min(n, count) end
  return math.max(count + n + 1, 1)
end

---@param signatures string[] heading signatures in document order
---@param sig string
---@return integer[] indexes of the headings whose tokens equal `sig`'s
function M.matches(signatures, sig)
  local want, out = signature.key(sig), {}
  for i, s in ipairs(signatures) do
    if signature.key(s) == want then out[#out + 1] = i end
  end
  return out
end

-- Following -------------------------------------------------------------------------------

---repeat counters of `N = 0` tags, by target and signature
---@type table<string, integer>
local cycle = {}

---Position among `count` matches for this activation
---@param key string target file and signature
---@param count integer
---@param n integer|nil
---@return integer
function M.next_position(key, count, n)
  if n == 0 then
    cycle[key] = ((cycle[key] or 0) % count) + 1
    return cycle[key]
  end
  return M.pick(count, n)
end

-- Following reindexes -------------------------------------------------------------------------

---@param bufnr integer
local function buf_src(bufnr)
  local src = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
  if vim.bo[bufnr].endofline then src = src .. '\n' end
  return src
end

---@param path string
---@return string|nil src
---@return integer|nil bufnr set when the file is loaded in a buffer
local function read(path)
  local bufnr = vim.fn.bufnr(path)
  if bufnr > 0 and vim.api.nvim_buf_is_loaded(bufnr) then return buf_src(bufnr), bufnr end
  local fh = io.open(path, 'rb')
  if not fh then return nil end
  local src = fh:read('*a')
  fh:close()
  return src
end

local tag_query

---@class FeyHeadingEntry
---@field title string
---@field old string signature before the reindex
---@field new string signature after the reindex

---Last known headings of a file (titles and signatures), the baseline for the next reindex.
---Section tags are always up to date with it, so it is the right "before" even when headings
---were typed or moved since: aligning it with the buffer by title tells which headings are new.
---@type table<string, { title: string, sig: string }[]>
local snapshots = {}

---Remember the current headings of a buffer
---@param bufnr integer
function M.snapshot(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == '' then return end
  local path = vim.fn.fnamemodify(name, ':p')
  local ok, headings = pcall(function()
    local src = buf_src(bufnr)
    local root = vim.treesitter.get_string_parser(src, 'fey'):parse()[1]:root()
    local out = {}
    local function walk(owner)
      for _, sec in ipairs(owner:field('subsection')) do
        local heading = sec:field('heading')[1]
        local sig = heading and heading:field('signature')[1]
        local title = heading and heading:field('title')[1]
        out[#out + 1] = {
          title = title and vim.trim(vim.treesitter.get_node_text(title, src)) or '',
          sig = sig and vim.trim(vim.treesitter.get_node_text(sig, src)) or '',
        }
        walk(sec)
      end
    end
    walk(root)
    return out
  end)
  if ok then snapshots[path] = headings end
end

---Pair up the entries of two heading lists by title (longest common subsequence)
---@param before { title: string }[]
---@param after { title: string }[]
---@return table<integer, integer> map index in `before` -> index in `after`
local function align(before, after)
  local n, m = #before, #after
  local lcs = {}
  for i = 0, n + 1 do
    lcs[i] = {}
    for j = 0, m + 1 do
      lcs[i][j] = 0
    end
  end
  for i = n, 1, -1 do
    for j = m, 1, -1 do
      if before[i].title == after[j].title then
        lcs[i][j] = lcs[i + 1][j + 1] + 1
      else
        lcs[i][j] = math.max(lcs[i + 1][j], lcs[i][j + 1])
      end
    end
  end
  local map, i, j = {}, 1, 1
  while i <= n and j <= m do
    if before[i].title == after[j].title then
      map[i], i, j = j, i + 1, j + 1
    elseif lcs[i + 1][j] >= lcs[i][j + 1] then
      i = i + 1
    else
      j = j + 1
    end
  end
  return map
end

local tag_query

---Edits that bring the section tags of one file in line with a reindex
---@param src string
---@param file_path string absolute path of the file that holds the tags
---@param target_path string absolute path of the reindexed file
---@param old string[] baseline signatures
---@param map table<integer, integer> baseline index -> index in `current`
---@param current string[] signatures after the reindex
---@param resolve fun(target: string, from: string): string|nil
---@return FeyDbEdit[]
local function plan(src, file_path, target_path, old, map, current, resolve)
  local source_edit = require('fey.db.source_edit')
  local config = require('fey.config')
  tag_query = tag_query or vim.treesitter.query.parse('fey', '[(scope_tag) (pair_tag) (line_tag) (block_tag)] @tag')
  local root = vim.treesitter.get_string_parser(src, 'fey'):parse()[1]:root()
  local offs = source_edit.row_offsets(src)
  local edits = {}

  for _, node in tag_query:iter_captures(root, src) do
    local head = node:type() == 'pair_tag' and node:field('open')[1] or node
    local name = head and head:field('name')[1]
    local tag_name = name and vim.treesitter.get_node_text(name, src)
    if tag_name == config.fey_section_tag_name or tag_name == config.fey_link_tag_name then
      local ref
      if tag_name == config.fey_section_tag_name then ref = M.read(node, src) else ref = M.read_link(node, src) end
      if ref then
        local target = ref.file and resolve(ref.file, file_path) or file_path
        if target and vim.uv.fs_realpath(target) == vim.uv.fs_realpath(target_path) then
          local found = M.matches(old, ref.signature)
          if #found > 0 and not (ref.n == 0 and #found > 1) then
            local at = found[M.pick(#found, ref.n)]
            local now_at = map[at]
            local new_sig = now_at and current[now_at]
            if new_sig and not signature.equal(new_sig, ref.signature) and ref.nodes.signature then
              local s, e = source_edit.span(ref.nodes.signature, src, offs)
              edits[#edits + 1] = { s = s, e = e, text = escape(new_sig) }

              -- keep N pointing at the same heading
              local now = M.matches(current, new_sig)
              local position
              for k, idx in ipairs(now) do
                if idx == now_at then position = k end
              end
              if position then
                local want
                if ref.n and ref.n < 0 then
                  want = -(#now - position + 1)
                elseif ref.n and ref.n > 0 then
                  want = position
                elseif position ~= 1 then
                  want = position
                end
                if want and want ~= ref.n then
                  if ref.nodes.n then
                    local ns, ne = source_edit.span(ref.nodes.n, src, offs)
                    edits[#edits + 1] = { s = ns, e = ne, text = tostring(want) }
                  else
                    local closures = head:field('tag_closure')
                    local tag_end = closures[#closures]
                    if tag_end then
                      local r, c = tag_end:range()
                      edits[#edits + 1] = { s = offs[r + 1] + c, e = offs[r + 1] + c, text = '; n: ' .. want }
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end
  return edits
end

---Rewrite the section tags that pointed at headings whose signatures just changed
---@param path string absolute path of the reindexed file
---@param entries FeyHeadingEntry[] every heading of the file, in document order
function M.on_reindex(path, entries)
  local current, current_titled = {}, {}
  local changed = false
  for i, e in ipairs(entries) do
    current[i] = e.new
    current_titled[i] = { title = e.title, sig = e.new }
    if e.old ~= e.new then changed = true end
  end

  local before = snapshots[path]
  snapshots[path] = current_titled
  if not changed then return end

  -- baseline: the last known state when there is one, else the buffer as it was
  local old, map = {}, {}
  if before then
    for i, h in ipairs(before) do
      old[i] = h.sig
    end
    map = align(before, current_titled)
  else
    for i, e in ipairs(entries) do
      old[i], map[i] = e.old, i
    end
  end

  vim.schedule(function()
    local fey_vault = require('fey.vault')
    local links = require('fey.links')
    local source_edit = require('fey.db.source_edit')
    local vault = fey_vault.for_path(path) or fey_vault.current()

    local files = { [path] = true }
    if vault then
      local rel = vim.fs.relpath(vault.root, vim.uv.fs_realpath(path) or path)
      if rel then
        local rows = vault:query(
          [[SELECT DISTINCT f.path FROM links l JOIN files f ON f.id = l.file_id
            WHERE l.target_file = :p]],
          { p = rel }
        )
        for _, r in ipairs(rows) do
          files[vim.fs.joinpath(vault.root, r.path)] = true
        end
      end
    end

    for file in pairs(files) do
      local src, bufnr = read(file)
      if src then
        local ok, edits = pcall(plan, src, file, path, old, map, current, links.resolve_path)
        if ok and #edits > 0 then source_edit.commit(vault, file, src, edits, bufnr) end
      end
    end
  end)
end

return M
