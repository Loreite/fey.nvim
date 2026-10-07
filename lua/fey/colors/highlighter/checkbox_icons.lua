-- Checkboxes shown as icons: `[x]` is hidden and an icon with the colour of its class is shown in its place
-- (the bracket is concealed with the icon as its replacement character). The line the cursor is on shows the box as written, so editing it is
-- not blind. Switched with `fey_show_checkbox_state_as_icons`, per buffer with `b:fey_show_checkbox_state_as_icons`.
--
-- The icons are Nerd Font glyphs when a Nerd Font is there (`fey_checkbox_icons = 'nerd'`, or `'auto'` and
-- nvim-web-devicons is installed) and plain one cell Unicode symbols otherwise. `fey_checkbox_icon_overrides`
-- changes single marks: `{ ['!'] = '' }`.
local config = require('fey.config')
local Checkbox = require('fey.files.elements.checkbox')

---@class FeyCheckboxIconsHighlighter
local Icons = {}
Icons.__index = Icons

local query

---@return vim.treesitter.Query
local function get_query()
  query = query or vim.treesitter.query.parse('fey', '(listitem checkbox: (checkbox) @box)')
  return query
end

---@param bufnr integer
---@return boolean
function Icons.enabled(bufnr)
  local override = vim.b[bufnr].fey_show_checkbox_state_as_icons
  if override ~= nil then return override and true or false end
  return config.fey_show_checkbox_state_as_icons and true or false
end

---Which icon set to use
---@return 'nerd'|'unicode'
function Icons.style()
  local setting = config.fey_checkbox_icons
  if setting == 'nerd' or setting == 'unicode' then return setting end
  -- a Nerd Font is taken for granted when nvim-web-devicons is there
  local has_devicons = package.loaded['nvim-web-devicons'] ~= nil or pcall(require, 'nvim-web-devicons')
  return has_devicons and 'nerd' or 'unicode'
end

---The icon of a mark: an override, else the glyph of the style
---@param mark string
---@return string
function Icons.icon_of(mark)
  local overrides = config.fey_checkbox_icon_overrides or {}
  if overrides[mark] and overrides[mark] ~= '' then return overrides[mark] end
  return Checkbox.icon(mark, Icons.style())
end

---@param opts { highlighter: FeyHighlighter }
function Icons:new(opts)
  return setmetatable({ highlighter = opts.highlighter }, self)
end

---@param bufnr integer
---@param line integer 0-based
---@param tree TSTree
function Icons:on_line(bufnr, line, tree)
  if not Icons.enabled(bufnr) then return end
  -- the cursor line stays as written
  if bufnr == vim.api.nvim_get_current_buf() and vim.api.nvim_win_get_cursor(0)[1] - 1 == line then return end
  local ns = self.highlighter.namespace
  local ephemeral = self.ephemeral ~= false -- (tests read real extmarks)
  require('fey.colors.highlighter.markup.emphasis').ensure_conceallevel(bufnr)

  for _, node in get_query():iter_captures(tree:root(), bufnr, line, line + 1) do
    local sr, sc, er, ec = node:range()
    if sr == line and er == line and not node:has_error() then
      local text = vim.treesitter.get_node_text(node, bufnr)
      local lead = #text:match('^%s*')
      local box = vim.trim(text)
      -- the node starts with the blanks before the bracket
      local from = sc + lead
      if #box == 3 then
        local mark = Checkbox.mark(box)
        local class = Checkbox.state_of_mark(mark).class
        -- the bracket is replaced by the icon (a concealed character shows its replacement, which an inline
        -- virtual text does not do in an ephemeral mark), the rest of the box disappears
        vim.api.nvim_buf_set_extmark(bufnr, ns, line, from, {
          ephemeral = ephemeral,
          end_col = from + 1,
          conceal = Icons.icon_of(mark),
          hl_group = '@fey.checkbox.' .. class,
          priority = 250,
        })
        vim.api.nvim_buf_set_extmark(bufnr, ns, line, from + 1, {
          ephemeral = ephemeral,
          end_col = ec,
          conceal = '',
          priority = 250,
        })
      end
    end
  end
end

return Icons
