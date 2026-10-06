-- Heading metadata tags (status: todo keyword and priority, labels) in a title are shown as their values: the
-- rest of the tag (`{# status, `, ` #}` and any keys) is concealed, and the value gets the face of what it
-- is. The cursor line shows the tags as written (the default 'concealcursor'), so editing them is not
-- blind. Switched with `fey_conceal_task_tags`, per buffer with `b:fey_conceal_task_tags`
-- (`<prefix>Tc` toggles it).
local config = require('fey.config')

---@class FeyTaskTagsHighlighter
---@field private namespace integer
local TaskTags = {}
TaskTags.__index = TaskTags

local query

---@return vim.treesitter.Query
local function get_query()
  query = query or vim.treesitter.query.parse('fey', '(heading title: (title [(scope_tag)] @tag))')
  return query
end

---@param bufnr integer
---@return boolean
function TaskTags.enabled(bufnr)
  local override = vim.b[bufnr].fey_conceal_task_tags
  if override ~= nil then return override and true or false end
  return config.fey_conceal_task_tags and true or false
end

---@param opts { highlighter: FeyHighlighter }
function TaskTags:new(opts)
  return setmetatable({ highlighter = opts.highlighter }, self)
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
    -- the blank in front of the priority is kept, so the two do not run together
    local from = i == 1 and fc + #text_of(value):match('^%s*') or fc
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

---@param bufnr integer
---@param line integer 0-based
---@param tree TSTree
function TaskTags:on_line(bufnr, line, tree)
  if not TaskTags.enabled(bufnr) then return end
  local ns = self.highlighter.namespace
  local ephemeral = self.ephemeral ~= false -- (tests read real extmarks)
  require('fey.colors.highlighter.markup.emphasis').ensure_conceallevel(bufnr)

  for _, node in get_query():iter_captures(tree:root(), bufnr, line, line + 1) do
    local sr, sc, er, ec = node:range()
    local name = node:field('name')[1]
    local kind = name and kind_of(vim.treesitter.get_node_text(name, bufnr))
    if kind and sr == line and er == line and not node:has_error() then
      local parts = visible_parts(node, kind, bufnr)
      if #parts > 0 then
        -- everything but the visible parts
        local from = sc
        for _, part in ipairs(parts) do
          if part.from > from then
            vim.api.nvim_buf_set_extmark(bufnr, ns, line, from, { ephemeral = ephemeral, end_col = part.from, conceal = '' })
          end
          from = part.to
          if part.face then
            vim.api.nvim_buf_set_extmark(bufnr, ns, line, part.from, {
              ephemeral = ephemeral,
              end_col = part.to,
              hl_group = part.face,
              priority = 250,
            })
          end
        end
        if ec > from then
          vim.api.nvim_buf_set_extmark(bufnr, ns, line, from, { ephemeral = ephemeral, end_col = ec, conceal = '' })
        end
      end
    end
  end
end

return TaskTags
