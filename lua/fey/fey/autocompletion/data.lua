-- What completion offers inside a tag: static knowledge of the tags the plugin has, and what the index of the hollow holds
-- (tag names with their counts, labels, files, headings, footnotes, the keys a tag was written with).
local config = require('fey.config')

local M = {}

---The keys of the document data that the plugin gives a meaning
M.DATA_KEYS = { 'title', 'category', 'todo', 'archive', 'header_args', 'labels', 'id', 'aliases', 'author', 'email' }

local SPANS = { 'today', 'yesterday', 'thisweek', 'lastweek', 'thismonth', 'lastmonth', 'thisyear', 'lastyear', 'all', '7d', '30d' }
local BOOLEAN = { 'true', 'false' }

---Keys a tag knows, by tag name; the index adds the keys written in the notes
---@return table<string, string[]>
local function static_keys()
  return {
    [config.fey_status_tag_name] = { 'priority' },
    [config.fey_date_tag_name] = { 'active' },
    [config.fey_scheduled_tag_name] = { 'active' },
    [config.fey_deadline_tag_name] = { 'active' },
    [config.fey_closed_tag_name] = { 'active' },
    [config.fey_clock_tag_name] = { 'end', 'dur' },
    [config.fey_link_tag_name] = { 'desc', 'section', 'n', 'conceal' },
    [config.fey_section_tag_name] = { 'file', 'n', 'conceal' },
    [config.fey_query_tag_name] = { 'scope', 'conceal' },
    [config.fey_db_tag_name] = { 'db', 'view', 'conceal' },
    [config.fey_clocktable_tag_name] = { 'span', 'by', 'scope', 'conceal' },
    [config.fey_query_result_tag_name] = { 'conceal' },
    [config.fey_db_result_tag_name] = { 'conceal' },
    [config.fey_clocktable_result_tag_name] = { 'conceal' },
    [config.fey_comment_tag_name] = { 'index' },
    [config.fey_hl_tag_name] = { 'fg', 'bg', 'bold', 'italic', 'strike', 'underline', 'link' },
    [config.fey_footnote_tag_name] = { 'form' },
    table = M.DATA_KEYS,
    array = {},
  }
end

---Values a key knows, by key name
---@return table<string, string[]>
local function static_key_values()
  return {
    scope = { 'current', 'tree', 'court' },
    by = { 'heading', 'file', 'day' },
    span = SPANS,
    conceal = BOOLEAN,
    active = BOOLEAN,
    index = BOOLEAN,
    bold = BOOLEAN,
    italic = BOOLEAN,
    strike = BOOLEAN,
    underline = BOOLEAN,
  }
end

---@return FeyVault|nil
local function vault()
  local fey_vault = require('fey.vault')
  local name = vim.api.nvim_buf_get_name(0)
  local v = (name ~= '' and fey_vault.for_path(name)) or fey_vault.current()
  return v and v.db and v or nil
end

---@param list string[]
---@return string[]
local function unique(list)
  local seen, out = {}, {}
  for _, item in ipairs(list) do
    if item ~= '' and not seen[item] then
      seen[item] = true
      out[#out + 1] = item
    end
  end
  return out
end

---The names of the tags: the ones the plugin has, then the ones written in the notes, most used first
---@return string[]
function M.tag_names()
  local names = {}
  for key, value in pairs(config.opts or config) do
    if type(key) == 'string' and key:match('^fey_.*_tag_name$') and type(value) == 'string' then names[#names + 1] = value end
  end
  table.sort(names)
  vim.list_extend(names, { 'table', 'array', 'value' })
  local v = vault()
  if v then
    for _, row in ipairs(v:query('SELECT name, COUNT(*) AS n FROM tags GROUP BY name ORDER BY n DESC')) do
      names[#names + 1] = row.name
    end
  end
  return unique(names)
end

---The keys a tag has: its own and the ones the notes use with it
---@param tag string
---@return string[]
function M.keys(tag)
  local keys = vim.deepcopy(static_keys()[tag] or {})
  if tag == config.fey_nvim_config_tag_name then
    vim.list_extend(keys, vim.fn.getcompletion('', 'option'))
  elseif tag == config.fey_plugin_tag_name then
    vim.list_extend(keys, require('fey.settings.fey_options').LIST)
  end
  local v = vault()
  if v then
    for _, row in ipairs(v:query('SELECT attrs FROM tags WHERE name = :name LIMIT 500', { name = tag })) do
      local ok, attrs = pcall(vim.json.decode, row.attrs or '{}')
      if ok and type(attrs) == 'table' then vim.list_extend(keys, vim.tbl_keys(attrs)) end
    end
  end
  return unique(keys)
end

---Headings signatures of the file of the buffer, or of the file a link names
---@param target? string
---@return string[]
local function signatures(target)
  local v = vault()
  if not v then return {} end
  local rel
  if target and target ~= '' then
    rel = target
    if not v:get_file(rel) and v:get_file(rel .. '.fey') then rel = rel .. '.fey' end
  else
    rel = v:rel_of(vim.api.nvim_buf_get_name(0))
  end
  local out = {}
  for _, h in ipairs(rel and v:headings(rel) or {}) do
    if h.signature and h.signature ~= '' then out[#out + 1] = h.signature end
  end
  return out
end

---The values of a tag, by position
---@param ctx FeyTagContext
---@return string[]
function M.values(ctx)
  local tag = ctx.tag
  local v = vault()
  if tag == config.fey_status_tag_name then
    if ctx.index == 1 then return config:get_todo_keywords():all_values() end
    local range = config:get_priority_range()
    return { range.highest, range.default, range.lowest }
  elseif tag == config.fey_labels_tag_name or tag == 'label' then
    return vim.tbl_map(function(l) return l.label end, v and v:labels() or {})
  elseif tag == config.fey_link_tag_name then
    if ctx.index ~= 1 then return {} end
    return vim.tbl_map(function(f) return f.path end, v and v:files() or {})
  elseif tag == config.fey_section_tag_name then
    if ctx.index == 1 then return signatures() end
    if ctx.index == 2 then return vim.tbl_map(function(f) return f.path end, v and v:files() or {}) end
  elseif tag == config.fey_footnote_tag_name then
    local out = {}
    for _, row in ipairs(v and v:footnotes() or {}) do
      out[#out + 1] = row.label
    end
    return out
  elseif tag == config.fey_clocktable_tag_name then
    if ctx.index == 1 then return SPANS end
  elseif tag == config.fey_plugin_tag_name then
    if ctx.index == 1 then
      local names = { 'fey' }
      vim.list_extend(names, vim.tbl_keys(require('fey.settings').plugin_handlers))
      return unique(names)
    end
  end
  return {}
end

---The values of a key
---@param ctx FeyTagContext
---@return string[]
function M.key_values(ctx)
  local key = ctx.key
  if key == 'section' or key == 'heading' then return signatures(ctx.values[1]) end
  if key == 'file' then
    local v = vault()
    return vim.tbl_map(function(f) return f.path end, v and v:files() or {})
  end
  if key == 'labels' or key == 'label' then
    local v = vault()
    return vim.tbl_map(function(l) return l.label end, v and v:labels() or {})
  end
  if key == 'todo' then return config:get_todo_keywords():all_values() end
  if key == 'colorscheme' then return vim.fn.getcompletion('', 'color') end
  if ctx.tag == config.fey_nvim_config_tag_name or ctx.tag == config.fey_plugin_tag_name then
    local info = require('fey.settings.options').info(key)
    if info and info.type == 'boolean' then return BOOLEAN end
  end
  return static_key_values()[key] or {}
end

return M
