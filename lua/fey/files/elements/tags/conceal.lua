-- Tags that conceal, from a declaration: one registry, one place that hides, one cursor rule.
--
-- A handler module says in a few lines that its tag conceals:
--
--   M.conceal = { mode = 'hide', default = 'fey_something_conceal_default' }
--
--   mode     'hide'   the tag goes, its body (if the form has one) stays
--            'icon'   the head becomes an icon (`icon`, over `fey_conceal_icons[name]`), the rest of the tag goes
--            'values' only the chosen parts of the head stay, in place: `values` lists positional values (numbers)
--                     and keys (strings); `hl` (or `hl_of(tag, key)`) gives them a face. `virtual(tag)` instead
--                     returns virtual text chunks shown where the head was (nil: the head only goes)
--   whole    the icon replaces the whole tag, body included (a `query` tag: its body is the query)
--   companion  fun(tag): TSNode|nil, a pair tag that goes with this tag as one object (a query and its result): its opener
--            and closer are hidden with it, the cursor rule covers both, and it does not conceal again on its own
--   parts    fun(tag): { from, to, face }[], `values` mode only: the columns (of the first row) that stay, in place of the
--            ones `values` names, when what stays depends on what the tag holds
--   where    fun(tag): boolean, the tag conceals only where this holds (a status tag: in the title of a heading)
--   state    fun(tag): boolean|nil, the default of this tag when it differs from the option (a buffer variable); nil: the option
--   default  the name of the option that decides when the tag has no `conceal` key (absent: not concealed)
--   icon     the icon, or { nerd = '', unicode = '' } to follow `fey_checkbox_icons`
--
-- A tag with no declaration is never concealed. `conceal: true|false` on a tag beats the default. With the cursor on any
-- row of the tag it is shown as written. Lines a tag fills are hidden whole (`conceal_lines`), so this needs `conceallevel`.
local config = require('fey.config')

local M = {}

local ns = vim.api.nvim_create_namespace('fey_tag_conceal_registry')
local timers = {}
---@type table<string, FeyConcealDecl>
local registry = {}
---@type table<integer, { groups: FeyConcealGroup[], active: table<integer, boolean> }>
local state = {}
local parse

---@class FeyConcealDecl
---@field mode 'hide'|'icon'|'values'
---@field default? string
---@field icon? string|{ nerd: string, unicode: string }
---@field whole? boolean
---@field companion? fun(tag: FeyTag): TSNode|nil
---@field values? (string|integer)[]
---@field parts? fun(tag: FeyTag): { from: integer, to: integer, face: string|nil }[]
---@field where? fun(tag: FeyTag): boolean
---@field state? fun(tag: FeyTag): boolean|nil
---@field hl? string
---@field hl_of? fun(tag: FeyTag, key: string|integer): string|nil
---@field virtual? fun(tag: FeyTag): table[]|nil

---@class FeyConcealGroup
---@field first integer
---@field last integer
---@field render fun(ids: integer[])
---@field ids integer[]

---@param name string
---@param decl FeyConcealDecl
function M.register(name, decl)
  vim.validate('conceal name', name, 'string')
  vim.validate('conceal mode', decl.mode, function(mode) return mode == 'hide' or mode == 'icon' or mode == 'values' end, "'hide', 'icon' or 'values'")
  registry[name] = decl
end

---@param name string
---@return FeyConcealDecl|nil
function M.declaration(name) return registry[name] end

---Forget every declaration (the tests use it)
function M.clear() registry = {} end

---@return boolean
function M.any() return next(registry) ~= nil end

---Does a tag conceal: its `conceal` key when it has one, else the default option of its declaration
---@param tag FeyTag
---@return boolean
function M.is_concealed(tag)
  local decl = registry[tag.name]
  if not decl then return false end
  if decl.where and not decl.where(tag) then return false end
  local value = tag.key_values.conceal
  if value ~= nil then return value:lower() == 'true' end
  if decl.state then
    local state = decl.state(tag)
    if state ~= nil then return state end
  end
  return decl.default ~= nil and config[decl.default] == true
end

---@param name string
---@param decl FeyConcealDecl
---@return string
local function icon_of(name, decl)
  local overrides = config.fey_conceal_icons or {}
  if overrides[name] then return overrides[name] end
  local icon = decl.icon or '?'
  if type(icon) == 'table' then
    return icon[require('fey.colors.highlighter.checkbox_icons').style()] or icon.unicode or '?'
  end
  return icon
end

local function line_of(bufnr, row) return vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or '' end

local function mark(bufnr, ids, row, col, opts)
  local ok, id = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, col, opts)
  if ok then ids[#ids + 1] = id end
end

---Hide a range, row by row: a row the range fills is hidden whole, else only its columns
---@param bufnr integer
---@param ids integer[]
---@param r { [1]: integer, [2]: integer, [3]: integer, [4]: integer } start row, start col, end row, end col
local function hide(bufnr, ids, r)
  local sr, sc, er, ec = r[1], r[2], r[3], r[4]
  if ec == 0 and er > sr then -- an end at column 0 belongs to the row before
    er = er - 1
    ec = #line_of(bufnr, er)
  end
  for row = sr, er do
    local line = line_of(bufnr, row)
    local from, to = row == sr and sc or 0, row == er and ec or #line
    if to > from then
      if line:sub(1, from):match('^%s*$') and line:sub(to + 1):match('^%s*$') then
        mark(bufnr, ids, row, 0, { end_row = row, end_col = #line, conceal_lines = '' })
      else
        mark(bufnr, ids, row, from, { end_row = row, end_col = to, conceal = '' })
      end
    end
  end
end

---The head of a tag and its tail (what follows the body), as ranges; a tag with no body is all head
---@param tag FeyTag
---@return integer[] head, integer[]|nil tail
local function pieces(tag, decl_whole)
  local node = tag.node
  if tag.type == 'pair_tag' then
    local open, close = node:field('open')[1], node:field('close')[1]
    return { open:range() }, close and { close:range() } or nil
  end
  local body = tag.type ~= 'scope_tag' and not decl_whole and tag.body or nil
  local sr, sc, er, ec = node:range()
  if not body then return { sr, sc, er, ec } end
  local bsr, bsc, ber, bec = body:range()
  local tail = (ber < er or bec < ec) and { ber, bec, er, ec } or nil
  return { sr, sc, bsr, bsc }, tail
end

---The columns of the chosen values of a tag head that sit on its first row: { from, to, face }
---@param tag FeyTag
---@param decl FeyConcealDecl
local function kept_spans(tag, decl)
  if decl.parts then return decl.parts(tag) end
  local head = tag.head
  local row = head:range()
  local spans = {}
  local function add(node, key)
    local sr, sc, er, ec = node:range()
    if sr ~= row or er ~= row then return end
    local text = vim.treesitter.get_node_text(node, tag.bufnr)
    local face = decl.hl_of and decl.hl_of(tag, key) or decl.hl
    spans[#spans + 1] = { from = sc + #text:match('^%s*'), to = ec - #text:match('%s*$'), face = face }
  end
  local positional = head:field('value')
  local pairs_ = {}
  for _, kv in ipairs(head:field('key_value')) do
    local k, v = kv:field('key')[1], kv:field('value')[1]
    if k and v then pairs_[vim.trim(vim.treesitter.get_node_text(k, tag.bufnr))] = v end
  end
  for _, want in ipairs(decl.values or {}) do
    local node = type(want) == 'number' and positional[want] or pairs_[want]
    if node then add(node, want) end
  end
  table.sort(spans, function(a, b) return a.from < b.from end)
  return spans
end

---@param bufnr integer
---@param ids integer[]
---@param tag FeyTag
---@param decl FeyConcealDecl
local function render(bufnr, ids, tag, decl)
  local head, tail = pieces(tag, decl.whole)
  if decl.mode == 'hide' then
    hide(bufnr, ids, head)
  elseif decl.mode == 'icon' then
    local sr, sc, er, ec = head[1], head[2], head[3], head[4]
    if ec == 0 and er > sr then
      er = er - 1
      ec = #line_of(bufnr, er)
    end
    local line = line_of(bufnr, sr)
    if line:sub(1, sc):match('^%s*$') and line_of(bufnr, er):sub(ec + 1):match('^%s*$') then
      mark(bufnr, ids, sr, 0, { end_row = sr, end_col = #line, conceal = icon_of(tag.name, decl) })
      if er > sr then hide(bufnr, ids, { sr + 1, 0, er, ec }) end
    else
      mark(bufnr, ids, sr, sc, { end_row = er, end_col = ec, conceal = icon_of(tag.name, decl) })
    end
  elseif decl.virtual then
    hide(bufnr, ids, head)
    local chunks = decl.virtual(tag)
    if chunks then mark(bufnr, ids, head[1], head[2], { virt_text = chunks, virt_text_pos = 'inline' }) end
  else
    local row, from = head[1], head[2]
    local last = head[4]
    if head[3] ~= row then last = #line_of(bufnr, row) end
    local kept = false
    for _, span in ipairs(kept_spans(tag, decl)) do
      if kept and span.from > from then
        -- the gap between two kept values shows one blank, so they do not run together
        mark(bufnr, ids, row, from, { end_col = span.from, conceal = ' ' })
      elseif span.from > from then
        hide(bufnr, ids, { row, from, row, span.from })
      end
      kept = true
      if span.face then
        mark(bufnr, ids, row, span.from, { end_col = span.to, hl_group = span.face, priority = 250 })
      end
      from = span.to
    end
    if last > from then hide(bufnr, ids, { row, from, row, last }) end
    if head[3] ~= row then hide(bufnr, ids, { row + 1, 0, head[3], head[4] }) end
  end
  if tail then hide(bufnr, ids, tail) end
  local companion = decl.companion and decl.companion(tag)
  if companion then
    local open, close = companion:field('open')[1], companion:field('close')[1]
    if open then hide(bufnr, ids, { open:range() }) end
    if close then hide(bufnr, ids, { close:range() }) end
  end
end

---Is the cursor of a window of the buffer in the group
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

---The tags of a buffer that conceal, as groups
---@param bufnr integer
---@param tags FeyTag[]
---@return FeyConcealGroup[]
local function groups_of(bufnr, tags)
  local groups = {}
  local used = {}
  for _, tag in ipairs(tags) do
    local decl = registry[tag.name]
    local companion = decl and decl.companion and M.is_concealed(tag) and decl.companion(tag)
    if companion then used[companion:id()] = true end
  end
  for _, tag in ipairs(tags) do
    local decl = registry[tag.name]
    if decl and M.is_concealed(tag) and not used[tag.node:id()] then
      local sr, _, er, ec = tag.node:range()
      local companion = decl.companion and decl.companion(tag)
      if companion then
        _, _, er, ec = companion:range()
      end
      if ec == 0 and er > sr then er = er - 1 end
      groups[#groups + 1] = {
        first = sr,
        last = er,
        ids = {},
        render = function(ids) render(bufnr, ids, tag, decl) end,
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
  if #state[bufnr].groups > 0 then require('fey.colors.highlighter.markup.emphasis').ensure_conceallevel(bufnr) end
  for i = 1, #state[bufnr].groups do
    draw(bufnr, i)
  end
end

---The cursor moved: draw again the tags it entered or left
---@param bufnr integer
function M.on_cursor(bufnr)
  local st = state[bufnr]
  if not st then return end
  for i, group in ipairs(st.groups) do
    if cursor_in(bufnr, group) ~= st.active[i] then draw(bufnr, i) end
  end
end

---Draw a buffer again, after an option changed
---@param bufnr integer
function M.refresh(bufnr)
  if not parse or not vim.api.nvim_buf_is_valid(bufnr) then return end
  local tags = parse(bufnr)
  if tags then M.apply(bufnr, tags) end
end

---@param parse_tags fun(bufnr: integer): FeyTag[]|false|nil
function M.setup(parse_tags)
  parse = parse_tags
  local group = vim.api.nvim_create_augroup('FeyTagConcealRegistry', { clear = true })
  vim.api.nvim_create_autocmd({ 'FileType', 'BufEnter', 'TextChanged', 'InsertLeave' }, {
    group = group,
    pattern = { 'fey', '*.fey' },
    callback = function(args)
      if timers[args.buf] then timers[args.buf]:stop() end
      timers[args.buf] = vim.defer_fn(function() M.refresh(args.buf) end, 100)
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
