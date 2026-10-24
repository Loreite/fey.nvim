-- The `conceal` key of link tags, and `fey_link_conceal_default`: the declaration of `link`, `embed` and the section tag
-- for the conceal registry (tags/conceal.lua), which hides them.
--
--   {@ link, notes/a.fey; desc: The notes; conceal: true @}      shows as   The notes
--   #[ link, notes/a.fey; conceal: true ] some words #           shows as   some words
--   [ link, notes/a.fey ]#   a block, the text under it is the link
--
-- Only the head is concealed: a scope tag is replaced by its description (or by what it points to), a line, block or
-- pair tag loses its head and its closer and keeps its body. The text of a link is drawn with `FeyLinkText`, linked to
-- `Underlined`.
local config = require('fey.config')
local conceal = require('fey.files.elements.tags.conceal')

local M = {}

---Does a link or section tag conceal: its `conceal` key, else `fey_link_conceal_default`
---@param key_values table<string, string>
---@return boolean
function M.is_concealed(key_values)
  local value = key_values.conceal
  if value ~= nil then return value:lower() == 'true' end
  return config.fey_link_conceal_default == true
end

---What a scope link shows in place of the tag
---@param tag FeyTag
---@return string
local function label(tag)
  if tag.name == config.fey_section_tag_name then
    local sig = tag.values[1] and tag.values[1]:gsub('\\(.)', '%1') or ''
    return '§ ' .. sig
  end
  local desc = tag.key_values.desc
  if desc and desc ~= '' then return (desc:gsub('\\(.)', '%1')) end
  local raw_target = tag.values[1] or tag.key_values.url or tag.key_values.file
  local target = raw_target and raw_target:gsub('\\(.)', '%1') or ''
  if target:match('^%a[%w+.-]*://') then return target end
  local name = vim.fn.fnamemodify(target, ':t:r')
  local sig = tag.key_values.section or tag.key_values.heading
  if name == '' then return sig and ('§ ' .. sig) or target end
  return sig and (name .. ' § ' .. sig) or name
end

---Declare the link tags to the registry
function M.declare()
  local function set_face() vim.api.nvim_set_hl(0, 'FeyLinkText', { link = 'Underlined', default = true }) end
  set_face()
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = vim.api.nvim_create_augroup('FeyLinkConceal', { clear = true }),
    callback = set_face,
  })
  local decl = {
    mode = 'values',
    default = 'fey_link_conceal_default',
    virtual = function(tag)
      if tag.type == 'scope_tag' then return { { label(tag), 'FeyLinkText' } } end
    end,
  }
  for _, name in ipairs({ config.fey_link_tag_name, config.fey_embed_tag_name, config.fey_section_tag_name }) do
    conceal.register(name, decl)
  end
end

---Draw a buffer again, after an option changed
---@param bufnr integer
function M.refresh(bufnr) conceal.refresh(bufnr) end

---The cursor moved: draw again the tags it entered or left
---@param bufnr integer
function M.on_cursor(bufnr) conceal.on_cursor(bufnr) end

M.ns = conceal.ns

return M
