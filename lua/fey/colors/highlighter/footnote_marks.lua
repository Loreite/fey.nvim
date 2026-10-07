-- Footnote labels as superscript: the syntax of a reference (`{@ fn, 1 @}`) is hidden and `¹` is shown in its
-- place, and the head of a definition in any form (`[ fn, 1 #]`, `#[ fn, 1 ]`, `[ fn, 1 ]#`) is hidden
-- the same way, so the note reads `¹ Measured twice.`. The label's characters are the replacement
-- characters of the concealed ones, so it works as every other conceal here. The line the cursor is on shows
-- the tags as written. `fey_footnote_superscript`: `auto` converts digits and signs (every font has them),
-- `true` letters too, `false` leaves the tags alone; `b:fey_footnote_superscript` per buffer. A label that
-- cannot be written whole stays as written.
local config = require('fey.config')
local Superscript = require('fey.footnotes.superscript')

---@class FeyFootnoteMarksHighlighter
local Marks = {}
Marks.__index = Marks

local query

---@return vim.treesitter.Query
local function get_query()
  query = query or vim.treesitter.query.parse('fey', '[(scope_tag) (line_tag) (block_tag) (pair_tag)] @tag')
  return query
end

---@param bufnr integer
---@return 'auto'|boolean
function Marks.mode(bufnr)
  local override = vim.b[bufnr].fey_footnote_superscript
  if override ~= nil then return override end
  return config.fey_footnote_superscript
end

---@param opts { highlighter: FeyHighlighter }
function Marks:new(opts)
  return setmetatable({ highlighter = opts.highlighter }, self)
end

---Hide a range of one line; `chars` (when given) replace its first characters
---@param self FeyFootnoteMarksHighlighter
---@param bufnr integer
---@param line integer
---@param from integer byte column
---@param to integer byte column, exclusive
---@param chars? string[]
local function conceal(self, bufnr, line, from, to, chars)
  local ns = self.highlighter.namespace
  local ephemeral = self.ephemeral ~= false
  local text = vim.api.nvim_buf_get_lines(bufnr, line, line + 1, false)[1] or ''
  local starts = vim.str_utf_pos(text:sub(from + 1, to))
  for i, start in ipairs(starts) do
    local col = from + start - 1
    local stop = starts[i + 1] and (from + starts[i + 1] - 1) or to
    local char = chars and chars[i] or ''
    vim.api.nvim_buf_set_extmark(bufnr, ns, line, col, {
      ephemeral = ephemeral,
      end_col = stop,
      conceal = char,
      hl_group = char ~= '' and '@fey.footnote.reference' or nil,
      priority = 250,
    })
  end
end

---@param bufnr integer
---@param line integer 0-based
---@param tree TSTree
function Marks:on_line(bufnr, line, tree)
  local mode = Marks.mode(bufnr)
  if mode == false then return end
  if bufnr == vim.api.nvim_get_current_buf() and vim.api.nvim_win_get_cursor(0)[1] - 1 == line then return end
  require('fey.colors.highlighter.markup.emphasis').ensure_conceallevel(bufnr)
  local Footnotes = require('fey.footnotes')

  for _, node in get_query():iter_captures(tree:root(), bufnr, line, line + 1) do
    local tag = not node:has_error() and Footnotes.read_tag(bufnr, node) or nil
    local sup = tag and Superscript.convert(tag.label, mode)
    if tag and sup then
      local chars = vim.fn.split(sup, '\\zs')
      local sr, sc, er, ec = node:range()
      if tag.form == 'scope' then
        if sr == line and er == line then conceal(self, bufnr, line, sc, ec, chars) end
      elseif tag.form == 'pair' then
        local open, close = node:field('open')[1], node:field('close')[1]
        if open then
          local osr, osc, oer, oec = open:range()
          if osr == line and oer == line then conceal(self, bufnr, line, osc, oec, chars) end
        end
        if close then
          local csr, csc, cer, cec = close:range()
          if csr == line and cer == line then conceal(self, bufnr, line, csc, cec) end
        end
      elseif sr == line then
        -- line and block tags: the head up to the end of its opener, and the closing hash of a line tag
        local head_end, trailer_from
        for child in node:iter_children() do
          if child:type() == 'tag_end' and not head_end then
            local _, _, _, cec = child:range()
            head_end = cec
          end
        end
        if tag.form == 'line' then
          local last = node:child(node:child_count() - 1)
          if last and last:type() == 'body_end' then
            local lsr, lsc = last:range()
            if lsr == line then trailer_from = lsc end
          end
        end
        if head_end then conceal(self, bufnr, line, sc, head_end, chars) end
        if trailer_from then conceal(self, bufnr, line, trailer_from, ec) end
      end
    end
  end
end

return Marks
