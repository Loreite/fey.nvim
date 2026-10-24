-- Heading metadata tags (status: todo keyword and priority, labels) in a title are shown as their values: the
-- rest of the tag (`{# status, `, ` #}` and any keys) is concealed, and the value gets the face of what it
-- is. The cursor line shows the tags as written, so editing them is not blind. Switched with
-- `fey_conceal_task_tags`, per buffer with `b:fey_conceal_task_tags` (`<prefix>Tc` toggles it).
--
-- The tags conceal through the registry of tags/conceal.lua, in `values` mode: this file declares them (`declare`) and
-- says what stays of each (`visible_parts`: the keyword and the priority of a status, the whole run of values of
-- labels with the commas between them, a priority given as a key) and the face of it.
local config = require('fey.config')

local TaskTags = {}

---@param bufnr integer
---@return boolean
function TaskTags.enabled(bufnr)
  local override = vim.b[bufnr].fey_conceal_task_tags
  if override ~= nil then return override and true or false end
  return config.fey_conceal_task_tags and true or false
end

---@param name string
---@return 'status'|'labels'|nil
local function kind_of(name)
  if name == config.fey_status_tag_name then return 'status' end
  if name == config.fey_labels_tag_name or vim.tbl_contains(config.vault.label_tags or {}, name) then return 'labels' end
end

---Face of a visible value
---@param what 'keyword'|'priority'|'label'
---@param value string
---@return string|nil
local function face_of(what, value)
  if what == 'keyword' then
    local faces = require('fey.colors.highlights').get_agenda_hl_map()
    if faces[value] then return faces[value] end
    local found = config:get_todo_keywords():find(value)
    if found then return found.type == 'DONE' and '@fey.keyword.done' or '@fey.keyword.todo' end
    return nil
  elseif what == 'priority' then
    local p = config:get_priorities()[value]
    return p and p.hl_group or nil
  end
  return '@fey.tag'
end

---What of a tag stays visible: a list of { from, to, face } (columns), in order.
---A status tag shows its keyword and its priority, the labels show all their values (and the commas
---between them).
---@param node TSNode
---@param kind string
---@param bufnr integer
---@return { from: integer, to: integer, face: string|nil }[]
local function visible_parts(node, kind, bufnr)
  local function text_of(n) return vim.treesitter.get_node_text(n, bufnr) end
  local parts = {}
  local values = node:field('value')

  if kind == 'labels' then
    if #values == 0 then return parts end
    local _, fc = values[1]:start()
    local _, lc = values[#values]:end_()
    parts[1] = { from = fc + #text_of(values[1]):match('^%s*'), to = lc, face = face_of('label', '') }
    return parts
  end

  -- status: `TODO, A`, or `; priority: A` without a keyword
  for i, value in ipairs(values) do
    if i > 2 then break end
    local _, fc = value:start()
    local _, ec = value:end_()
    local text = vim.trim(text_of(value))
    -- the blank in front of the priority is kept, so the two do not run together (the node holds it or it is just before the node)
    local from = fc + #text_of(value):match('^%s*')
    if i > 1 then
      local row = value:start()
      local before = vim.api.nvim_buf_get_text(bufnr, row, math.max(fc - 1, 0), row, fc, {})[1] or ''
      from = (text_of(value):match('^%s') or before:match('^%s')) and (text_of(value):match('^%s') and fc or fc - 1) or fc
    end
    parts[#parts + 1] = { from = from, to = ec, face = face_of(i == 1 and 'keyword' or 'priority', text) }
  end
  if #parts == 0 then
    for _, kv in ipairs(node:field('key_value')) do
      local key, value = kv:field('key')[1], kv:field('value')[1]
      if key and value and vim.trim(text_of(key)) == 'priority' then
        local _, fc = value:start()
        local _, ec = value:end_()
        parts[1] = {
          from = fc + #text_of(value):match('^%s*'),
          to = ec,
          face = face_of('priority', vim.trim(text_of(value))),
        }
      end
    end
  end
  return parts
end

---Is the tag a status or labels tag in the title of a heading, on one row
---@param tag FeyTag
---@return boolean
local function in_title(tag)
  local sr, _, er = tag.node:range()
  local parent = tag.node:parent()
  return sr == er and parent ~= nil and parent:type() == 'title' and not tag.node:has_error()
end

---Declare the status and labels tags to the registry
function TaskTags.declare()
  local conceal = require('fey.files.elements.tags.conceal')
  local names = { config.fey_status_tag_name, config.fey_labels_tag_name }
  vim.list_extend(names, config.vault.label_tags or {})
  for _, name in ipairs(names) do
    conceal.register(name, {
      mode = 'values',
      default = 'fey_conceal_task_tags',
      where = in_title,
      state = function(tag)
        local override = vim.b[tag.bufnr].fey_conceal_task_tags
        if override ~= nil then return override and true or false end
      end,
      parts = function(tag) return visible_parts(tag.node, kind_of(tag.name), tag.bufnr) end,
    })
  end
end

return TaskTags
