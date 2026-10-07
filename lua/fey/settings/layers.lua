-- Reading the settings that a piece of Fey text asks for: its `nvim` tags (editor options, `colorscheme`) and its
-- `plugin` tags (options of a plugin). A layer is what one text says; the settings of a note are several layers
-- merged, see `fey.settings`.
--
--   {# nvim; colorscheme: tokyonight; wrap: false; tabstop: 4 #}
--   {# plugin, fey; fey_conceal_task_tags: false #}
--
-- A tag takes its options as keys. For nested options a pair or a block tag takes a body that is read like the
-- body of a `table` tag (keys ending in an underscore, sublists, arrays):
--
--   [ plugin, fey #]
--   fey_checkbox_icons_:  nerd
--   notifications_:
--       reminder_time_:  5
--   [# plugin ]
local config = require('fey.config')

local M = {}

---@class FeySettingsLayer
---@field source string where it comes from (a path, or `buffer`)
---@field nvim table<string, any> options of the editor
---@field plugins table<string, table<string, any>> options by plugin name
---@field tags table[] the tags it was made of (`{ name, type, row }`)

local query

---@return vim.treesitter.Query
local function get_query()
  query = query or vim.treesitter.query.parse('fey', '[(scope_tag) (line_tag) (block_tag) (pair_tag)] @tag')
  return query
end

---A value written as text, as Lua: true and false, numbers, else the text
---@param value any
---@return any
function M.coerce(value)
  if type(value) ~= 'string' then return value end
  if value == 'true' then return true end
  if value == 'false' then return false end
  local n = tonumber(value)
  if n and value:match('^%-?%d+%.?%d*$') then return n end
  return value
end

---Data without the metatables of the data model, so it compares and merges like plain Lua
---@param data any
---@return any
local function plain(data)
  if type(data) ~= 'table' then return data end
  return vim.json.decode(vim.json.encode(data), { luanil = { object = true, array = true } })
end

---The data a pair or block body holds, read as the body of a table tag
---@param lines string[] all the lines of the text
---@param node TSNode the body node
---@param form 'pair_tag'|'block_tag'
---@return table
local function body_data(lines, node, form)
  local sr, sc, er, ec = node:range()
  -- a body that starts in the middle of the opener's line starts on the next one
  if sc > 0 and (lines[sr + 1] or ''):sub(sc + 1):match('^%s*$') then sr = sr + 1 end
  local last = ec == 0 and er - 1 or er
  local body = vim.list_slice(lines, sr + 1, last + 1)
  local src
  if form == 'pair_tag' then
    src = '[ table #]\n' .. table.concat(body, '\n') .. '\n[# table ]\n'
  else
    src = '[ table ]#\n' .. table.concat(body, '\n') .. '\n'
  end
  local ok, meta = pcall(require('fey.vault.extract').extract, src)
  if not ok or type(meta.data) ~= 'table' then return {} end
  return plain(meta.data) or {}
end

---The layer a text makes
---@param source integer|string a buffer, or the text
---@param label? string
---@return FeySettingsLayer|nil layer nil when the text does not parse (mid-typing): the caller keeps what it had
function M.read(source, label)
  local parser, lines
  if type(source) == 'number' then
    if not vim.api.nvim_buf_is_valid(source) then return nil end
    parser = vim.treesitter.get_parser(source, 'fey')
    lines = vim.api.nvim_buf_get_lines(source, 0, -1, false)
  else
    parser = vim.treesitter.get_string_parser(source, 'fey')
    lines = vim.split(source, '\n', { plain = true })
  end
  local root = parser:parse()[1]:root()
  if root:has_error() then return nil end

  local Tag = require('fey.files.elements.tags')
  local layer = { source = label or (type(source) == 'number' and 'buffer' or 'text'), nvim = {}, plugins = {}, tags = {} }
  for _, node in get_query():iter_captures(root, source) do
    local tag = Tag.parse_tag_node(source, node)
    local is_nvim = tag.name == config.fey_nvim_config_tag_name
    local is_plugin = tag.name == config.fey_plugin_tag_name
    if is_nvim or is_plugin then
      local options = {}
      for key, value in pairs(tag.key_values) do
        options[key] = M.coerce(value)
      end
      if tag.body and (tag.type == 'pair_tag' or tag.type == 'block_tag') then
        for key, value in pairs(body_data(lines, tag.body, tag.type)) do
          options[key] = value
        end
      end
      local row = node:start()
      layer.tags[#layer.tags + 1] = { name = tag.name, type = tag.type, row = row }
      if is_nvim then
        for key, value in pairs(options) do
          layer.nvim[key] = value
        end
      else
        local name = tag.values[1]
        if name and name ~= '' then layer.plugins[name] = vim.tbl_deep_extend('force', layer.plugins[name] or {}, options) end
      end
    end
  end
  return layer
end

---The layer of one tag node of a buffer (to apply a single tag)
---@param bufnr integer
---@param node TSNode
---@return FeySettingsLayer
function M.read_tag(bufnr, node)
  -- a pair or block tag needs its lines, so the lines the tag covers are read as a text of their own
  local sr, _, er = node:range()
  local lines = vim.api.nvim_buf_get_lines(bufnr, sr, er + 1, false)
  return M.read(table.concat(lines, '\n') .. '\n', 'tag') or { source = 'tag', nvim = {}, plugins = {}, tags = {} }
end

return M
