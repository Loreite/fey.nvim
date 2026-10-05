---@class FeyNavigatorConfig
---@field width number        Total popup width (fraction of &columns if <= 1)
---@field height number       Popup height (fraction of &lines if <= 1)
---@field nav_width number    Left pane width (fraction of total if <= 1)
---@field border string|table|nil  nil = &winborder (0.11+) or 'rounded'
---@field context_lines integer  Subdued lines shown above/below the target
---@field preview_max_lines integer  Preview is truncated past this many lines
---@field label_max integer   Max label width in the navigation pane
---@field icons table<string, string>
---@field keys table<string, string|string[]>

local M = {}

---@type FeyNavigatorConfig
M.defaults = {
  width = 0.85,
  height = 0.75,
  nav_width = 0.38,
  border = nil,
  context_lines = 2,
  preview_max_lines = 2000,
  label_max = 60,
  -- Set filetype=fey on the preview buffer (runs fey's ftplugin). When false
  -- the preview only starts the fey tree-sitter highlighter.
  preview_filetype = false,
  -- Plain open() resumes the last position instead of starting at the root.
  resume_by_default = false,
  icons = {
    category = '▸',
    heading = '§',
    list = '≡',
    listitem = '•',
    block = '▤',
    table = '▦',
    row = '│',
    tag = '◇',
    paragraph = '¶',
    has_children = '›',
  },
  keys = {
    down = 'j',
    up = 'k',
    enter = 'l',
    back = 'h',
    local_root = '<Tab>',
    jump = '<CR>',
    filter = '/',
    scroll_up = '<C-u>',
    scroll_down = '<C-d>',
    close = { 'q', '<Esc>' },
  },
}

---@type FeyNavigatorConfig
M.options = vim.deepcopy(M.defaults)

---@param opts? table
function M.set(opts)
  M.options = vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), opts or {})
end

return M
