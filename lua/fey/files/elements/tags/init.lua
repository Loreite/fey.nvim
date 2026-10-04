local config = require('fey.config')
local utils = require('fey.utils')
local nvim_config = require('fey.files.elements.tags.handlers.nvim_config')

---@type vim.treesitter.Query
local query = nil

---@class FeyTag
---@field node TSNode
---@field bufnr integer
---@field type string
---@field name string
---@field values string[]
---@field key_values table
local Tag = {}

---@param opts table
function Tag:new(opts)
  local data = {
    node = opts.node,
    bufnr = opts.bufnr,
    type = opts.type,
    name = opts.name,
    values = opts.values,
    key_values = opts.key_values,
  }

  setmetatable(data, self)
  self.__index = self
  return data
end

function Tag:apply()
  if Tag.handlers[self.name] and Tag.handlers[self.name][self.type] then
    --
    Tag.handlers[self.name][self.type](self)
  end
end

function Tag.parse_tag_node(bufnr, node)
  local name = node:field('name')[1]
  local name_text = vim.treesitter.get_node_text(name, bufnr)

  local values = {}
  for _, value in ipairs(node:field('value')) do
    local text = vim.treesitter.get_node_text(value, bufnr)
    table.insert(values, text:match('^%s*(.-)%s*$'))
  end

  local key_values = {}
  for _, kv in ipairs(node:field('key_value')) do
    local key = kv:field('key')[1]
    local value = kv:field('value')[1]

    if key and value then
      local key_text = vim.treesitter.get_node_text(key, bufnr)
      local value_text = vim.treesitter.get_node_text(value, bufnr)

      -- value_text = utils.unquote(value_text)
      value_text = value_text:match('^%s*(.-)%s*$')
      key_values[key_text] = value_text
    end
  end

  local opts = {
    node = node,
    bufnr = bufnr,
    type = node:type(),
    name = name_text,
    values = values,
    key_values = key_values,
  }

  return Tag:new(opts)
end

function Tag.parse_all_tags(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then return end

  local tree = vim.treesitter.get_parser(bufnr, 'fey', {}):parse()
  if not tree or #tree == 0 then return false end

  local root = tree[1]:root()
  if root:has_error() then return false end

  local tags = {}
  for _, node in query:iter_captures(root, bufnr) do -- id, node: (root, bufnr, 0, -1)
    table.insert(tags, Tag.parse_tag_node(bufnr, node))
  end

  return tags
end

Tag.handlers = {}

function Tag.setup(handlers)
  handlers = handlers or {}
  vim.validate('fey_nvim_config_tag_name', config.fey_nvim_config_tag_name, 'string')
  vim.validate('key_handlers', handlers, 'table')
  for name, handler in pairs(handlers) do
    vim.validate('key_handlers key', name, 'string')
    vim.validate('key_handlers.' .. name, handler, 'function')
  end
  Tag.handlers[config.fey_nvim_config_tag_name] = nvim_config.handlers
  Tag.handlers = vim.tbl_deep_extend('force', Tag.handlers, handlers)

  query = query or vim.treesitter.query.get('fey', 'fey_tags')

  nvim_config.setup_query(Tag.parse_all_tags)
end

return Tag
