local ts_utils = require('fey.utils.treesitter')
local indent = require('fey.fey.indent')

---@class FeyListitem
---@field listitem TSNode
---@field file FeyFile
local Listitem = {}

---@return FeyListitem
function Listitem:new(listitem_node, file)
  local data = {
    listitem = listitem_node,
    file = file,
  }
  setmetatable(data, self)
  self.__index = self
  return data
end

function Listitem:get_new_checkbox_value(action, current_value, total_child_checkboxes, checked_child_checkboxes)
  if action == 'on' then
    return '[X]'
  elseif action == 'off' then
    return '[ ]'
  elseif action == 'toggle' then
    return (current_value == '[X]' or current_value == '[x]') and '[ ]' or '[X]'
  elseif action == 'children' then
    if #checked_child_checkboxes == 0 then
      return '[ ]'
    elseif #checked_child_checkboxes == #total_child_checkboxes then
      return '[X]'
    end
  end
  return '[-]'
end

function Listitem:checkbox()
  local checkbox = self.listitem:field('checkbox')[1]
  if not checkbox then return nil end
  local text = self.file:get_node_text(checkbox)
  return { text = text, range = { checkbox:range() } }
end

function Listitem:update_checkbox(action)
  action = action or 'toggle'

  local checkbox = self:checkbox()
  local total_child_checkboxes = self:child_checkboxes() or {}
  local checked_child_checkboxes = vim.tbl_filter(function(box) return box:match('%[%w%]') end, total_child_checkboxes)

  if checkbox then
    vim.api.nvim_buf_set_text(
      0,
      checkbox.range[1],
      checkbox.range[2],
      checkbox.range[3],
      checkbox.range[4],
      { self:get_new_checkbox_value(action, checkbox.text, total_child_checkboxes, checked_child_checkboxes) }
    )
  end

  self:update_cookie(total_child_checkboxes, checked_child_checkboxes)

  local parent_list = ts_utils.closest_node(self.listitem, 'list')
  local parent_listitem = ts_utils.closest_node(parent_list, 'listitem')
  if parent_listitem then
    Listitem:new(parent_listitem, self.file):update_checkbox('children')
  else
    local parent_heading = self.file:get_closest_heading_or_nil()
    if parent_heading then parent_heading:update_cookie() end
  end
end

function Listitem:child_checkboxes()
  local contents = self.listitem:field('contents')
  for _, content in ipairs(contents) do
    if content:type() == 'list' then
      return vim.tbl_map(function(node)
        local text = self.file:get_node_text(node)
        return text:match('%[.%]')
      end, ts_utils.get_named_children(content))
    end
  end
end

function Listitem:cookie()
  local content = self.listitem:field('contents')[1]
  -- The cookie should be the last thing on the line
  local cookie_node = content:named_child(content:named_child_count() - 1)
  if not cookie_node then return nil end

  local text = self.file:get_node_text(cookie_node)
  if text:match('%[%d*/%d*%]') or text:match('%[%d?%d?%d?%%%]') then return cookie_node end
end

function Listitem:update_cookie(total_child_checkboxes, checked_child_checkboxes)
  local cookie = self:cookie()
  if cookie then
    local new_cookie_val
    if self.file:get_node_text(cookie):find('%%') then
      new_cookie_val = ('[%d%%]'):format((#checked_child_checkboxes / #total_child_checkboxes) * 100)
    else
      new_cookie_val = ('[%d/%d]'):format(#checked_child_checkboxes, #total_child_checkboxes)
    end
    self.file:set_node_text(cookie, new_cookie_val)
  end
end

---@return TSNode|nil
function Listitem:_get_parent_listitem()
  local list = self.listitem:parent()
  local parent = list and list:parent()
  if parent and parent:type() == 'listitem' then return parent end
  return nil
end

---@return TSNode|nil
function Listitem:_get_list_parent_list()
  local parent_listitem = self:_get_parent_listitem()
  if parent_listitem then return parent_listitem:parent() end
  return nil
end

---@param listitem_node TSNode
---@return number
local function get_overhang(listitem_node)
  local bullet = assert(listitem_node:named_child(0))
  return vim.trim(vim.treesitter.get_node_text(bullet, 0)):len() + 2
end

---@param line string
---@param delta number
---@return string
local function adjust_line_indent(line, delta)
  if delta > 0 then
    return (' '):rep(delta) .. line
  elseif delta < 0 then
    local current_indent = #(line:match('^%s*'))
    local remove = math.min(-delta, current_indent)
    return line:sub(remove + 1)
  end
  return line
end

---@param delta number
---@param include_childs boolean
function Listitem:_adjust_lines(delta, include_childs)
  if delta == 0 then return end

  local start_row, _, end_row, _ = self.listitem:range()
  if not include_childs then end_row = start_row + 1 end

  local lines = vim.api.nvim_buf_get_lines(0, start_row, end_row, false)
  for i, line in ipairs(lines) do
    lines[i] = adjust_line_indent(line, delta)
  end
  vim.api.nvim_buf_set_lines(0, start_row, end_row, false, lines)
end

---@param include_childs boolean
function Listitem:promote(include_childs)
  local start_row = self.listitem:range()
  local current_indent = vim.fn.indent(start_row + 1)

  local parent_list = self:_get_list_parent_list()
  local target_indent
  if parent_list then
    local list_start_row = parent_list:range()
    target_indent = indent.indentexpr(list_start_row + 1)
  else
    target_indent = math.max(current_indent - 2, 0)
  end

  self:_adjust_lines(target_indent - current_indent, include_childs)
end

---@param include_childs boolean
function Listitem:demote(include_childs)
  local start_row = self.listitem:range()
  local current_indent = vim.fn.indent(start_row + 1)
  local target_listitem = self.listitem:prev_sibling()
  while target_listitem and target_listitem:type() ~= 'listitem' do
    target_listitem = target_listitem:prev_sibling()
  end
  target_listitem = target_listitem and target_listitem or self:_get_parent_listitem()
  local target_indent
  if target_listitem then
    local target_start_row = target_listitem:range()
    local listitem_indent = indent.indentexpr(target_start_row + 1)
    target_indent = listitem_indent + get_overhang(target_listitem)
  else
    target_indent = current_indent + 2
  end

  self:_adjust_lines(target_indent - current_indent, include_childs)
end

---@param node TSNode
---@return number start_row, number end_row 0-indexed, end exclusive
local function get_row_span(node)
  local start_row, _, end_row, end_col = node:range()
  if end_col > 0 then end_row = end_row + 1 end
  return start_row, end_row
end

---@param direction 'prev'|'next'
---@return TSNode|nil
function Listitem:_get_sibling_listitem(direction)
  local sibling = direction == 'prev' and self.listitem:prev_sibling() or self.listitem:next_sibling()
  while sibling and sibling:type() ~= 'listitem' do
    sibling = direction == 'prev' and sibling:prev_sibling() or sibling:next_sibling()
  end
  return sibling
end

--- Swap this listitem (with its sublist) with its previous/next sibling.
---@param direction 'up'|'down'
---@return boolean moved
function Listitem:move(direction)
  local sibling = self:_get_sibling_listitem(direction == 'up' and 'prev' or 'next')
  if not sibling then return false end

  local start_row, end_row = get_row_span(self.listitem)
  local sib_start, sib_end = get_row_span(sibling)
  local first_start, first_end, second_start, second_end
  if direction == 'up' then
    first_start, first_end, second_start, second_end = sib_start, sib_end, start_row, end_row
  else
    first_start, first_end, second_start, second_end = start_row, end_row, sib_start, sib_end
  end
  if first_end ~= second_start then return false end

  local first = vim.api.nvim_buf_get_lines(0, first_start, first_end, false)
  local second = vim.api.nvim_buf_get_lines(0, second_start, second_end, false)
  local lines = vim.list_extend(vim.deepcopy(second), first)
  vim.api.nvim_buf_set_lines(0, first_start, second_end, false, lines)

  local cursor = vim.api.nvim_win_get_cursor(0)
  local offset = cursor[1] - 1 - start_row
  local new_start = direction == 'up' and sib_start or (start_row + (sib_end - sib_start))
  vim.api.nvim_win_set_cursor(0, { new_start + offset + 1, cursor[2] })
  return true
end

return Listitem
