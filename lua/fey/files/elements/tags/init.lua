local config = require('fey.config')
local utils = require('fey.utils')
local nvim_config = require('fey.files.elements.tags.handlers.nvim_config')
local hl = require('fey.files.elements.tags.handlers.hl')
local query_handler = require('fey.files.elements.tags.handlers.query')
local feydb_handler = require('fey.files.elements.tags.handlers.feydb')
local link_handler = require('fey.files.elements.tags.handlers.link')
local section_handler = require('fey.files.elements.tags.handlers.section')
local date_handler = require('fey.files.elements.tags.handlers.date')
local status_handler = require('fey.files.elements.tags.handlers.status')

---@type vim.treesitter.Query
local query = nil

---@class FeyTag
---@field node TSNode
---@field head TSNode
---@field body TSNode
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
    head = opts.head,
    body = opts.body,
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
  local head = node:type() == 'pair_tag' and node:field('open')[1] or node
  local name = head:field('name')[1]
  local name_text = vim.treesitter.get_node_text(name, bufnr)
  local body
  if node:type() == 'scope_tag' then
    body = node:parent()
  elseif node:type() == 'line_tag' then
    -- the line tag body is an unnamed child rather than a field
    for child in node:iter_children() do
      if child:type() == 'body' then body = child end
    end
  else
    body = node:field('body')[1]
  end

  local values = {}
  for _, value in ipairs(head:field('value')) do
    local text = vim.treesitter.get_node_text(value, bufnr)
    table.insert(values, text:match('^%s*(.-)%s*$'))
  end

  local key_values = {}
  for _, kv in ipairs(head:field('key_value')) do
    local key = kv:field('key')[1]
    local value = kv:field('value')[1]

    if key and value then
      local key_text = vim.treesitter.get_node_text(key, bufnr)
      local value_text = vim.treesitter.get_node_text(value, bufnr)

      value_text = value_text:match('^%s*(.-)%s*$')
      key_values[vim.trim(key_text)] = value_text
    end
  end

  local opts = {
    node = node,
    head = head,
    body = body,
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

---@type table<string, boolean> names of the tags the open-at-point mapping applies the handler of
Tag.at_point = {}

function Tag.setup(handlers)
  handlers = handlers or {}
  vim.validate('fey_nvim_config_tag_name', config.fey_nvim_config_tag_name, 'string')
  vim.validate('key_handlers', handlers, 'table')
  for name, handler in pairs(handlers) do
    vim.validate('key_handlers key', name, 'string')
    vim.validate('key_handlers.' .. name, handler, 'function')
  end
  vim.validate('fey_hl_tag_name', config.fey_hl_tag_name, 'string')
  vim.validate('fey_query_tag_name', config.fey_query_tag_name, 'string')
  Tag.handlers[config.fey_nvim_config_tag_name] = nvim_config.handlers
  Tag.handlers[config.fey_hl_tag_name] = hl.handlers
  Tag.handlers[config.fey_query_tag_name] = query_handler.handlers
  Tag.handlers[config.fey_db_tag_name] = feydb_handler.handlers
  Tag.handlers[config.fey_link_tag_name] = link_handler.handlers
  Tag.handlers[config.fey_section_tag_name] = section_handler.handlers
  Tag.handlers[config.fey_status_tag_name] = status_handler.handlers
  Tag.handlers[config.fey_footnote_tag_name] = require('fey.footnotes').handlers
  -- tags the open-at-point mapping applies the handler of (the others are run by their own mappings)
  Tag.at_point = { [config.fey_status_tag_name] = true, [config.fey_footnote_tag_name] = true }
  for _, name in ipairs(date_handler.names()) do
    Tag.handlers[name] = date_handler.handlers
    Tag.at_point[name] = true
  end
  Tag.handlers = vim.tbl_deep_extend('force', Tag.handlers, handlers)

  query = query or vim.treesitter.query.get('fey', 'fey_tags')

  nvim_config.setup_query(Tag.parse_all_tags)
  hl.setup_query(Tag.parse_all_tags)
end

return Tag
