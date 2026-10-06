local ts_utils = require('fey.utils.treesitter')
local TextObjects = {}

---Last 1-indexed line covered by a node (a zero-width end at column 0 belongs to the previous line)
---@param node TSNode
---@return number
local function last_line(node)
  local _, _, end_row, end_col = node:range()
  if end_col == 0 then end_row = end_row - 1 end
  return end_row + 1
end

---@return TSNode|nil
local function current_section()
  return ts_utils.closest_node(ts_utils.get_node_at_cursor(), 'section')
end

---@param section TSNode
---@return TSNode
local function root_section(section)
  local parent = section:parent()
  while parent and parent:type() == 'section' do
    section = parent
    parent = section:parent()
  end
  return section
end

---Last line of the section's own content, i.e. up to its first subsection
---@param section TSNode
---@return number
local function heading_last_line(section)
  for _, child in ipairs(ts_utils.get_named_children(section)) do
    if child:type() == 'section' then return child:start() end -- 0-indexed row == previous 1-indexed line
  end
  return last_line(section)
end

---Column (0-indexed) where the title of the section's heading starts
---@param section TSNode
---@return number
local function title_col(section)
  local heading = section:field('heading')[1]
  local title = heading and heading:field('title')[1]
  if title then
    local _, col = title:range()
    return col
  end
  local sig = heading and heading:field('signature')[1]
  if sig then
    local _, _, _, col = sig:range()
    return col
  end
  return 0
end

---@param start_row number 1-indexed
---@param end_row number 1-indexed
---@param inner_col? number 0-indexed column to start a charwise selection on `start_row`
local function select_range(start_row, end_row, inner_col)
  vim.fn.cursor({ start_row, (inner_col or 0) + 1 })
  local motion = end_row > start_row and ('%dgg'):format(end_row) or ''
  if inner_col then
    vim.cmd(('norm!v%s$'):format(motion))
  else
    vim.cmd(('norm!V%s'):format(motion))
  end
end

---@param inner boolean exclude the signature
---@param from_root boolean start from the root section instead of the current one
---@param subtree boolean include subsections
local function select_section(inner, from_root, subtree)
  local section = current_section()
  if not section then return end
  local start_node = from_root and root_section(section) or section
  local end_row = subtree and last_line(from_root and root_section(section) or section) or heading_last_line(section)
  local start_row = start_node:start() + 1
  select_range(start_row, end_row, inner and title_col(start_node) or nil)
end

function TextObjects.inner_heading() select_section(true, false, false) end
function TextObjects.around_heading() select_section(false, false, false) end
function TextObjects.inner_subtree() select_section(true, false, true) end
function TextObjects.around_subtree() select_section(false, false, true) end
function TextObjects.inner_heading_from_root() select_section(true, true, false) end
function TextObjects.around_heading_from_root() select_section(false, true, false) end
function TextObjects.inner_subtree_from_root() select_section(true, true, true) end
function TextObjects.around_subtree_from_root() select_section(false, true, true) end

return TextObjects
