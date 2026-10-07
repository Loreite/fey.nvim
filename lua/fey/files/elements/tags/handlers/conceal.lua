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
-- Lines a node fills are hidden whole (`conceal_lines`), so this needs `conceallevel`.
local config = require('fey.config')

local M = {}

local ns = vim.api.nvim_create_namespace('fey_tag_conceal')
local timers = {}
---@type table<integer, { groups: table[], active: table<integer, boolean> }>
local state = {}

local ICONS = {
  nerd = { query = '\u{f1c0}', feydb = '\u{f1c0}', clocktable = '\u{f017}' },
  unicode = { query = '≣', feydb = '≣', clocktable = '◷' },
}

---@return table<string, 'source'|'result'>
local function names()
  return {
    [config.fey_query_tag_name] = 'source',
    [config.fey_db_tag_name] = 'source',
    [config.fey_clocktable_tag_name] = 'source',
    [config.fey_query_result_tag_name] = 'result',
    [config.fey_db_result_tag_name] = 'result',
    [config.fey_clocktable_result_tag_name] = 'result',
  }
end

---Does a query, feydb or clocktable tag conceal: its `conceal` key when it has one (so `conceal: false` beats the default),
---else `fey_query_conceal_default`
---@param key_values table<string, string>
---@return boolean
function M.is_concealed(key_values)
  local value = key_values.conceal
  if value ~= nil then return value:lower() == 'true' end
  return config.fey_query_conceal_default == true
end

---The icon for a tag name
---@param name string
---@return string
function M.icon(name)
  local overrides = config.fey_conceal_icons or {}
  if overrides[name] then return overrides[name] end
  local set = ICONS[require('fey.colors.highlighter.checkbox_icons').style()]
  local kind = (name == config.fey_clocktable_tag_name or name == config.fey_clocktable_result_tag_name) and 'clocktable'
    or (name == config.fey_db_tag_name or name == config.fey_db_result_tag_name) and 'feydb'
    or 'query'
  return set[kind]
end

local function line_of(bufnr, row) return vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or '' end

---The range of a node as rows and columns, an end at column 0 belonging to the row before
---@param bufnr integer
---@param node TSNode
---@return integer sr, integer sc, integer er, integer ec
local function range_of(bufnr, node)
  local sr, sc, er, ec = node:range()
  if ec == 0 and er > sr then
    er = er - 1
    ec = #line_of(bufnr, er)
  end
  return sr, sc, er, ec
end

---Does a node fill its lines
local function fills(bufnr, sr, sc, er, ec)
  return line_of(bufnr, sr):sub(1, sc):match('^%s*$') ~= nil and line_of(bufnr, er):sub(ec + 1):match('^%s*$') ~= nil
end

---@param bufnr integer
---@param ids integer[]
---@param row integer
---@param col integer
---@param opts table
local function mark(bufnr, ids, row, col, opts)
  local ok, id = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, col, opts)
  if ok then ids[#ids + 1] = id end
end

---Hide the lines of a node
local function hide_lines(bufnr, ids, node)
  local sr, _, er, ec = range_of(bufnr, node)
  mark(bufnr, ids, sr, 0, { end_row = er, end_col = math.max(ec, #line_of(bufnr, er)), conceal_lines = '' })
end

---Replace a node with the icon: its first line becomes the icon, its other lines are hidden
local function icon_for(bufnr, ids, node, icon)
  local sr, sc, er, ec = range_of(bufnr, node)
  if fills(bufnr, sr, sc, er, ec) then
    mark(bufnr, ids, sr, 0, { end_row = sr, end_col = #line_of(bufnr, sr), conceal = icon })
    if er > sr then
      mark(bufnr, ids, sr + 1, 0, { end_row = er, end_col = #line_of(bufnr, er), conceal_lines = '' })
    end
  else
    mark(bufnr, ids, sr, sc, { end_row = er, end_col = ec, conceal = icon })
  end
end

---@class FeyConcealGroup
---@field first integer row of the first line of the object
---@field last integer row of its last line
---@field render fun(ids: integer[]) draw the hidden state
---@field ids integer[]

---Is the cursor of a window of the buffer in the group
---@param bufnr integer
---@param group FeyConcealGroup
local function cursor_in(bufnr, group)
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    local row = vim.api.nvim_win_get_cursor(win)[1] - 1
    if row >= group.first and row <= group.last then return true end
  end
  return false
end

local function draw(bufnr, i)
  local st = state[bufnr]
  local group = st.groups[i]
  for _, id in ipairs(group.ids) do
    pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, id)
  end
  group.ids = {}
  st.active[i] = cursor_in(bufnr, group)
  if not st.active[i] then group.render(group.ids) end
end

---The objects of a buffer that conceal
---@param bufnr integer
---@param tags FeyTag[]
---@return FeyConcealGroup[]
local function groups_of(bufnr, tags)
  local query = require('fey.query')
  local groups = {}
  local used = {}
  local kinds = names()
  for _, tag in ipairs(tags) do
    if kinds[tag.name] == 'source' and M.is_concealed(tag.key_values) then
      local node = tag.node
      local result = query.result_node(bufnr, node)
      local sr = node:range()
      local last_row = select(3, range_of(bufnr, result or node))
      if result then used[result:id()] = true end
      groups[#groups + 1] = {
        first = sr,
        last = last_row,
        ids = {},
        render = function(ids)
          icon_for(bufnr, ids, node, M.icon(tag.name))
          if result then
            local open, close = result:field('open')[1], result:field('close')[1]
            if open then hide_lines(bufnr, ids, open) end
            if close then hide_lines(bufnr, ids, close) end
          end
        end,
      }
    end
  end
  for _, tag in ipairs(tags) do
    if
      kinds[tag.name] == 'result'
      and tag.type == 'pair_tag'
      and not used[tag.node:id()]
      and (tag.key_values.conceal or ''):lower() == 'true'
    then
      local node = tag.node
      local open, close = node:field('open')[1], node:field('close')[1]
      groups[#groups + 1] = {
        first = (node:range()),
        last = select(3, range_of(bufnr, node)),
        ids = {},
        render = function(ids)
          if open then icon_for(bufnr, ids, open, M.icon(tag.name)) end
          if close then hide_lines(bufnr, ids, close) end
        end,
      }
    end
  end
  return groups
end

---Draw the buffer again from its tags
---@param bufnr integer
---@param tags FeyTag[]
function M.apply(bufnr, tags)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  state[bufnr] = { groups = groups_of(bufnr, tags), active = {} }
  for i = 1, #state[bufnr].groups do
    draw(bufnr, i)
  end
end

---The cursor moved: draw again the objects it entered or left
---@param bufnr integer
function M.on_cursor(bufnr)
  local st = state[bufnr]
  if not st then return end
  for i, group in ipairs(st.groups) do
    if cursor_in(bufnr, group) ~= st.active[i] then draw(bufnr, i) end
  end
end

local parse
---Draw a buffer again, after an option changed
---@param bufnr integer
function M.refresh(bufnr)
  if not parse or not vim.api.nvim_buf_is_valid(bufnr) then return end
  local tags = parse(bufnr)
  if tags then M.apply(bufnr, tags) end
end

function M.setup_query(parse_tags)
  parse = parse_tags
  local group = vim.api.nvim_create_augroup('FeyTagConceal', { clear = true })
  local apply_all = function(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    local tags = parse_tags(bufnr)
    if not tags then return end
    M.apply(bufnr, tags)
  end
  vim.api.nvim_create_autocmd({ 'FileType', 'BufEnter', 'TextChanged', 'InsertLeave' }, {
    group = group,
    pattern = { 'fey', '*.fey' },
    callback = function(args)
      if timers[args.buf] then timers[args.buf]:stop() end
      timers[args.buf] = vim.defer_fn(function() apply_all(args.buf) end, 100)
    end,
  })
  vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI', 'WinEnter' }, {
    group = group,
    pattern = { 'fey', '*.fey' },
    callback = function(args) M.on_cursor(args.buf) end,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    callback = function(args)
      state[args.buf] = nil
      timers[args.buf] = nil
    end,
  })
end

M.ns = ns

return M
