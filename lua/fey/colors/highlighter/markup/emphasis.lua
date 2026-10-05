local config = require('fey.config')

---@class FeyEmphasisHighlighter : FeyMarkupHighlighter
---@field private markup FeyMarkupHighlighter
local FeyEmphasis = {}

-- ---------------------------------------------------------------------------
-- Markers
--
--   x  -> `xtextx`   single marker  -> hl `@fey.<name>`
--   xx -> `xxtextxx` double marker  -> hl `@fey.<name>.highlight`
--
-- Every marker is one grammar token, so a double marker is two adjacent
-- tokens of the same type. A run of three or more is plain text.
--
-- `kind` decides the behaviour inside the span:
--   style / color  nestable: other emphasis may appear inside
--   code / verbatim / quote  NOT nestable: the inside is taken literally
--
-- The highlight groups themselves are defined in fey.colors.highlights
-- (keep `name` in sync with EMPHASIS_GROUPS there).
-- ---------------------------------------------------------------------------
local markers = {
  -- fg + text style
  ['_'] = { name = 'underline', kind = 'style' },
  ['!'] = { name = 'bold', kind = 'style' },
  ['/'] = { name = 'italic', kind = 'style' },
  ['~'] = { name = 'strikethrough', kind = 'style' },
  -- colours
  ['$'] = { name = 'red', kind = 'color' },
  ['^'] = { name = 'orange', kind = 'color' },
  ['*'] = { name = 'green', kind = 'color' },
  ['&'] = { name = 'yellow', kind = 'color' },
  ['%'] = { name = 'fuscia', kind = 'color' },
  ['#'] = { name = 'blue', kind = 'color' },
  ['='] = { name = 'purple', kind = 'color' },
  ['-'] = { name = 'teal', kind = 'color' },
  ['+'] = { name = 'dim', kind = 'color' },
  -- verbatim: six interchangeable delimiters, so one that does not occur in
  -- the literal text can always be chosen
  ['?'] = { name = 'verbatim', kind = 'verbatim' },
  [','] = { name = 'verbatim', kind = 'verbatim' },
  [';'] = { name = 'verbatim', kind = 'verbatim' },
  -- plain verbatim: literal like the above, but its groups are empty, so the
  -- text takes whatever highlight an outer marker gives it (`$red .x. red$`)
  ['.'] = { name = 'plain', kind = 'verbatim' },
  [':'] = { name = 'plain', kind = 'verbatim' },
  -- code
  ['`'] = { name = 'code', kind = 'code' },
  -- quotes
  ["'"] = { name = 'quote', kind = 'quote' },
  ['"'] = { name = 'quote', kind = 'quote' },
}

local literal_kinds = { code = true, verbatim = true, quote = true }
local no_spell_kinds = { code = true, verbatim = true }

-- Capture names in queries/fey/markup.scm are `emphasis.<name>`.
FeyEmphasis.valid_capture_names = {}
for _, m in pairs(markers) do
  FeyEmphasis.valid_capture_names['emphasis.' .. m.name] = true
end

---@param char string marker as stored on the entry: one char, or two for a double
---@return { hl_name: string, nestable: boolean, spell: boolean? }?
local function marker_info(char)
  local m = markers[char:sub(1, 1)]
  if not m then return nil end
  local double = #char == 2
  return {
    hl_name = '@fey.' .. m.name .. (double and '.highlight' or ''),
    nestable = not literal_kinds[m.kind],
    spell = no_spell_kinds[m.kind] and false or nil,
  }
end

-- ---- surrounding characters ---------------------------------------------

---@param source number | string
---@param line number 0-based
---@return string
local function get_line(source, line)
  if type(source) == 'number' then return vim.api.nvim_buf_get_lines(source, line, line + 1, false)[1] or '' end
  return vim.split(source, '\n', { plain = true })[line + 1] or ''
end

---@param text string
---@param col number 0-based byte column
---@return string?
local function char_at(text, col)
  if col < 0 then return nil end
  local c = text:sub(col + 1, col + 1)
  return c ~= '' and c or nil
end

local function is_space(c) return c ~= nil and c:match('%s') ~= nil end

-- A marker may be preceded (opener) / followed (closer) by the line edge,
-- whitespace, or any ASCII punctuation (brackets, quotes and other markers,
-- so emphasis can nest: `!/both/!`, `($red$)`).
local function is_boundary(c) return c == nil or c:match('[%s%p]') ~= nil end

-- ---- construction --------------------------------------------------------

---@param opts { markup: FeyMarkupHighlighter }
function FeyEmphasis:new(opts)
  local data = {
    markup = opts.markup,
  }
  setmetatable(data, self)
  self.__index = self
  return data
end

local function same_row_adjacent(a, b)
  local a_row, _, a_end_row, a_end_col = a:range()
  local b_row, b_col = b:range()
  return a_end_row == b_row and a_row == b_row and a_end_col == b_col
end

---@param node TSNode
---@param name string
---@return FeyMarkupNode | false
function FeyEmphasis:parse_node(node, name)
  if not self.valid_capture_names[name] then return false end
  local node_type = node:type()
  if not markers[node_type] then return false end

  -- The second marker of a double (or anything inside a longer run) is
  -- handled through the first one.
  local prev_node = node:prev_sibling()
  if prev_node and prev_node:type() == node_type and same_row_adjacent(prev_node, node) then return false end

  local char = node_type
  local range = self.markup:node_to_range(node)

  local next_node = node:next_sibling()
  if next_node and next_node:type() == node_type and same_row_adjacent(node, next_node) then
    local after = next_node:next_sibling()
    if after and after:type() == node_type and same_row_adjacent(next_node, after) then
      return false -- `!!!`: three or more is plain text
    end
    char = node_type .. node_type
    range = vim.tbl_extend('force', range, { end_col = self.markup:node_to_range(next_node).end_col })
  end

  local info = marker_info(char) --[[@as table]]
  local id = 'emphasis_' .. char

  return {
    type = 'emphasis',
    char = char,
    id = id,
    seek_id = id,
    nestable = info.nestable,
    range = range,
    node = node,
  }
end

-- Tokens of an expr that are part of a word. Everything else in an expr is
-- a single punctuation token (a marker, bracket, quote, ...).
local WORD_TOKENS = { str = true, num = true, escape = true }

-- True when every sibling from `node` onward in `direction` ('prev' or
-- 'next') is punctuation, i.e. `node` sits at that edge of its expr (a
-- word, since exprs are split on whitespace).
local function at_expr_edge(node, direction)
  local step = direction == 'prev' and node.prev_sibling or node.next_sibling
  local sibling = step(node)
  while sibling do
    if WORD_TOKENS[sibling:type()] then return false end
    sibling = step(sibling)
  end
  return true
end

-- Last marker node of the entry (the second one of a double).
local function last_marker(entry)
  if #entry.char == 2 then return entry.node:next_sibling() or entry.node end
  return entry.node
end

---@param entry FeyMarkupNode
---@param source number | string
---@return boolean
function FeyEmphasis:is_valid_start_node(entry, source)
  -- Only at the start of a word: `([a-z]*_)` has no opener at `*`.
  if not at_expr_edge(entry.node, 'prev') then return false end
  local text = get_line(source, entry.range.line)
  local before = char_at(text, entry.range.start_col - 1)
  local after = char_at(text, entry.range.end_col)
  return is_boundary(before) and after ~= nil and not is_space(after)
end

---@param entry FeyMarkupNode
---@param source number | string
---@return boolean
function FeyEmphasis:is_valid_end_node(entry, source)
  -- Only at the end of a word.
  if not at_expr_edge(last_marker(entry), 'next') then return false end
  local text = get_line(source, entry.range.line)
  local before = char_at(text, entry.range.start_col - 1)
  local after = char_at(text, entry.range.end_col)
  return before ~= nil and not is_space(before) and is_boundary(after)
end

-- ---- highlighting --------------------------------------------------------

---@param highlights FeyMarkupHighlight[]
---@return FeyMarkupPreparedHighlight[]
function FeyEmphasis:prepare_highlights(highlights)
  local hide_markers = config.fey_hide_emphasis_markers
  local ephemeral = self.markup:use_ephemeral()
  local conceal = hide_markers and '' or nil
  local extmarks = {}

  for _, entry in ipairs(highlights) do
    local info = marker_info(entry.char)
    if info then
      local line = entry.from.line
      local priority = 110 + entry.from.start_col

      -- Leading delimiter (one or two chars)
      table.insert(extmarks, {
        start_line = line,
        start_col = entry.from.start_col,
        end_col = entry.from.end_col,
        ephemeral = ephemeral,
        hl_group = info.hl_name .. '.delimiter',
        spell = info.spell,
        priority = priority,
        conceal = conceal,
      })

      -- Closing delimiter
      table.insert(extmarks, {
        start_line = line,
        start_col = entry.to.start_col,
        end_col = entry.to.end_col,
        ephemeral = ephemeral,
        hl_group = info.hl_name .. '.delimiter',
        spell = info.spell,
        priority = priority,
        conceal = conceal,
      })

      -- Body, between the delimiters
      table.insert(extmarks, {
        start_line = line,
        start_col = entry.from.end_col,
        end_col = entry.to.start_col,
        ephemeral = ephemeral,
        hl_group = info.hl_name,
        spell = info.spell,
        priority = priority,
      })
    end
  end

  return extmarks
end

-- ---- :Inspect support ------------------------------------------------------
--
-- Emphasis is drawn with ephemeral extmarks (from a decoration provider).
-- Nvim never stores those, so :Inspect cannot find them, unlike treesitter
-- highlights, which it re-queries itself. highlight() therefore records what
-- it drew on each line, keyed by the line's text so a record can never
-- outlive an edit, and vim.inspect_pos (which :Inspect uses) is wrapped to
-- report the records under the cursor as extmarks.

local drawn = {} -- bufnr -> row -> { text, ns, marks, seen }

local function record(bufnr, namespace, marks)
  if bufnr == 0 then bufnr = vim.api.nvim_get_current_buf() end
  local buf = drawn[bufnr]
  if not buf then
    buf = {}
    drawn[bufnr] = buf
  end
  for _, mark in ipairs(marks) do
    local row = mark.start_line
    local text = get_line(bufnr, row)
    local rec = buf[row]
    if not rec or rec.text ~= text then
      rec = { text = text, ns = namespace, marks = {}, seen = {} }
      buf[row] = rec
    end
    local key = table.concat({ mark.start_col, mark.end_col, mark.hl_group }, ':')
    if not rec.seen[key] then -- redraws repeat the same marks
      rec.seen[key] = true
      table.insert(rec.marks, mark)
    end
  end
end

local function namespace_name(id)
  for name, ns in pairs(vim.api.nvim_get_namespaces()) do
    if ns == id then return name end
  end
  return ''
end

-- Same as inspect_pos: the group a highlight finally resolves to (itself when
-- it is not a link). show_pos needs this to be a string.
local function final_link(name)
  local resolved = vim.fn.synIDattr(vim.fn.synIDtrans(vim.fn.hlID(name)), 'name')
  return resolved ~= '' and resolved or name
end

local function install_inspect_hook()
  if FeyEmphasis._inspect_hooked or type(vim.inspect_pos) ~= 'function' then return end
  FeyEmphasis._inspect_hooked = true

  local original = vim.inspect_pos
  vim.inspect_pos = function(bufnr, row, col, filter)
    local items = original(bufnr, row, col, filter)
    pcall(function()
      if filter and filter.extmarks == false then return end
      bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
      if row == nil or col == nil then
        local cursor = vim.api.nvim_win_get_cursor(0)
        row = row or cursor[1] - 1
        col = col or cursor[2]
      end
      local rec = drawn[bufnr] and drawn[bufnr][row]
      if not rec or rec.text ~= get_line(bufnr, row) then return end
      items.extmarks = items.extmarks or {}
      local ns = namespace_name(rec.ns)
      for _, m in ipairs(rec.marks) do
        if m.start_col <= col and col < m.end_col then
          table.insert(items.extmarks, {
            id = 0,
            ns_id = rec.ns,
            ns = ns,
            row = row,
            col = m.start_col,
            end_row = row,
            end_col = m.end_col,
            opts = {
              ns_id = rec.ns,
              end_row = row,
              end_col = m.end_col,
              hl_group = m.hl_group,
              hl_group_link = final_link(m.hl_group),
              priority = m.priority,
            },
          })
        end
      end
    end)
    return items
  end

  vim.api.nvim_create_autocmd('BufWipeout', {
    group = vim.api.nvim_create_augroup('FeyEmphasisInspect', { clear = true }),
    callback = function(args) drawn[args.buf] = nil end,
  })
end

install_inspect_hook()

-- ---- conceal ----------------------------------------------------------------
--
-- Extmark `conceal` only takes effect in windows whose 'conceallevel' is 2 or
-- more, and Neovim's default is 0. With fey_hide_emphasis_markers on, raise
-- it (window-local, for this buffer) in every window showing a fey buffer.
-- Deferred because highlight() runs inside a redraw. The cursor line still
-- shows its markers unless 'concealcursor' includes the current mode.

local conceal_pending = {}

local function ensure_conceallevel(bufnr)
  if conceal_pending[bufnr] then return end
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.wo[win].conceallevel < 2 then
      conceal_pending[bufnr] = true
      vim.schedule(function()
        conceal_pending[bufnr] = nil
        for _, w in ipairs(vim.fn.win_findbuf(bufnr)) do
          if vim.api.nvim_win_is_valid(w) and vim.wo[w].conceallevel < 2 then
            vim.api.nvim_set_option_value('conceallevel', 2, { scope = 'local', win = w })
          end
        end
      end)
      return
    end
  end
end

---@param highlights FeyMarkupHighlight[]
---@param bufnr number
function FeyEmphasis:highlight(highlights, bufnr)
  local namespace = self.markup.highlighter.namespace
  if bufnr == 0 then bufnr = vim.api.nvim_get_current_buf() end
  if config.fey_hide_emphasis_markers then ensure_conceallevel(bufnr) end
  local marks = self:prepare_highlights(highlights)
  if self.markup:use_ephemeral() then
    record(bufnr, namespace, marks) -- real extmarks already show in :Inspect
  end
  for _, mark in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(bufnr, namespace, mark.start_line, mark.start_col, {
      ephemeral = mark.ephemeral,
      end_col = mark.end_col,
      hl_group = mark.hl_group,
      spell = mark.spell,
      priority = mark.priority,
      conceal = mark.conceal,
    })
  end
end

return FeyEmphasis
