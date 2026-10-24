-- The `conceal` key of the tags that run (`query`, `feydb`, `clocktable`) and of their results.
--
--   {# query, LIST FROM #design; conceal: true #}
--
-- `fey_query_conceal_default` conceals them all; `conceal: false` on a tag keeps that one in view.
-- A concealed query and its result are one object. Away from it the page shows the result and one icon where the
-- query was, so you know the data is imported: the tag and its body are hidden, so are the head and the closer of the
-- result. With the cursor anywhere from the first line of the query to the last line of the result everything is
-- shown as written, so it can be read and edited. When the tag runs it writes the result with `conceal: true` too
-- (`[ query_result; conceal: true #]`); a result that has the key but no concealed query is one object of its own.
--
-- The icon is a Nerd Font glyph or a one cell symbol (see `fey_checkbox_icons`), `fey_conceal_icons` changes it by tag name.
-- The drawing is the registry of `tags/conceal.lua`; this module only declares the six tags.
local config = require('fey.config')

local M = {}

local ICONS = {
  query = { nerd = '\u{f1c0}', unicode = '≣' },
  feydb = { nerd = '\u{f1c0}', unicode = '≣' },
  clocktable = { nerd = '\u{f017}', unicode = '◷' },
}

---Does a query, feydb or clocktable tag conceal: its `conceal` key when it has one (so `conceal: false` beats the default),
---else `fey_query_conceal_default`
---@param key_values table<string, string>
---@return boolean
function M.is_concealed(key_values)
  local value = key_values.conceal
  if value ~= nil then return value:lower() == 'true' end
  return config.fey_query_conceal_default == true
end

---The result of a query tag, the pair tag that goes with it
local function result_of(tag) return require('fey.query').result_node(tag.bufnr, tag.node) end

---Declare the tags to the registry
function M.declare()
  local registry = require('fey.files.elements.tags.conceal')
  for _, kind in ipairs({
    { 'query', config.fey_query_tag_name, config.fey_query_result_tag_name },
    { 'feydb', config.fey_db_tag_name, config.fey_db_result_tag_name },
    { 'clocktable', config.fey_clocktable_tag_name, config.fey_clocktable_result_tag_name },
  }) do
    local icon = ICONS[kind[1]]
    registry.register(kind[2], {
      mode = 'icon',
      whole = true,
      icon = icon,
      default = 'fey_query_conceal_default',
      companion = result_of,
    })
    -- a result with `conceal: true` and no concealed query is one object of its own (no default: only the key)
    registry.register(kind[3], { mode = 'icon', icon = icon })
  end
end

---Draw a buffer again, after an option changed
---@param bufnr integer
function M.refresh(bufnr) require('fey.files.elements.tags.conceal').refresh(bufnr) end

return M
