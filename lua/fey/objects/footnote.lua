local Range = require('fey.files.elements.range')
local ts_utils = require('fey.utils.treesitter')

---@class FeyFootnote
---@field label string
---@field range FeyRange
---@field is_reference boolean
local FeyFootnote = {}
FeyFootnote.__index = FeyFootnote

---@param label string
---@param range FeyRange
---@param is_reference boolean
---@return FeyFootnote
function FeyFootnote:new(label, range, is_reference)
  local this = setmetatable({}, { __index = FeyFootnote })
  this.label = label
  this.range = range
  this.is_reference = is_reference or false
  return this
end

function FeyFootnote:get_name()
  return self.label
end

---@param node TSNode | nil
---@param source? number | string
---@return FeyFootnote | nil
function FeyFootnote.from_node(node, source)
  local fnode = ts_utils.closest_node(ts_utils.get_node(), { 'fnref', 'fndef' })
  if not fnode then
    return nil
  end

  local text = vim.treesitter.get_node_text(fnode:field('label')[1], source or 0)
  return FeyFootnote:new(text, Range.from_node(node), fnode:type() == 'fnref')
end

---@return FeyFootnote | nil
function FeyFootnote.at_cursor()
  return FeyFootnote.from_node(ts_utils.get_node(), vim.api.nvim_get_current_buf())
end

return FeyFootnote
