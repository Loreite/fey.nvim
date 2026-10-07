-- The `conceal` key of link tags, and `fey_link_conceal_default`.
--
--   {@ link, notes/a.fey; desc: The notes; conceal: true @}      shows as   The notes
--   #[ link, notes/a.fey; conceal: true ] some words #           shows as   some words
--   [ link, notes/a.fey ]#   a block, the text under it is the link
--
-- Only the head is concealed: a scope tag is replaced by its description (or by what it points to), a line, block or
-- pair tag loses its head and its closer and keeps its body. Unlike a concealed query, a link comes back on the line of
-- the cursor and only there. The text of a link is drawn with `FeyLinkText`, linked to `Underlined`.
local config = require('fey.config')

local M = {}

local ns = vim.api.nvim_create_namespace('fey_link_conceal')
local timers = {}
---@type table<integer, { pieces: table[], active: table<integer, boolean> }>
local state = {}
local parse

---Does a link or section tag conceal: its `conceal` key, else `fey_link_conceal_default`
---@param key_values table<string, string>
---@return boolean
function M.is_concealed(key_values)
  local value = key_values.conceal
  if value ~= nil then return value:lower() == 'true' end
  return config.fey_link_conceal_default == true
end

local function line_of(bufnr, row) return vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or '' end

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
  local target = tag.values[1] and tag.values[1]:gsub('\\(.)', '%1') or ''
  if target:match('^%a[%w+.-]*://') then return target end
  local name = vim.fn.fnamemodify(target, ':t:r')
  local sig = tag.key_values.section or tag.key_values.heading
  if name == '' then return sig and ('§ ' .. sig) or target end
  return sig and (name .. ' § ' .. sig) or name
end

---The pieces of a tag that are hidden: each is one row, so each shows or hides on its own
---@param bufnr integer
---@param tag FeyTag
---@return table[]
local function pieces_of(bufnr, tag)
  local node = tag.node
  local out = {}
  ---@param sr integer
  ---@param sc integer
  ---@param er integer
  ---@param ec integer
  ---@param text? string what to show in place
  local function piece(sr, sc, er, ec, text)
    if ec == 0 and er > sr then
      er = er - 1
      ec = #line_of(bufnr, er)
    end
    local fills = line_of(bufnr, sr):sub(1, sc):match('^%s*$') and line_of(bufnr, er):sub(ec + 1):match('^%s*$')
    out[#out + 1] = { row = sr, last = er, sc = sc, ec = ec, fills = fills and not text, text = text, er = er }
  end

  if node:type() == 'scope_tag' then
    local sr, sc, er, ec = node:range()
    piece(sr, sc, er, ec, label(tag))
    return out
  end
  local head = node:type() == 'pair_tag' and node:field('open')[1] or node
  local first, last
  for _, c in ipairs(head:field('tag_closure')) do
    if c:type() == 'tag_start' and not first then first = c end
    if c:type() == 'tag_end' then last = c end
  end
  if first and last then
    local sr, sc = first:range()
    local _, _, er, ec = last:range()
    piece(sr, sc, er, ec)
  end
  if node:type() == 'pair_tag' then
    local close = node:field('close')[1]
    if close then piece(close:range()) end
  elseif node:type() == 'line_tag' then
    for child in node:iter_children() do
      if child:type() == 'body_end' then piece(child:range()) end
    end
  end
  return out
end

local function draw(bufnr, i)
  local st = state[bufnr]
  local piece = st.pieces[i]
  for _, id in ipairs(piece.ids or {}) do
    pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, id)
  end
  piece.ids = {}
  local shown = false
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    local row = vim.api.nvim_win_get_cursor(win)[1] - 1
    if row >= piece.row and row <= piece.last then shown = true end
  end
  st.active[i] = shown
  if shown then return end
  local function mark(row, col, opts)
    local ok, id = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, col, opts)
    if ok then piece.ids[#piece.ids + 1] = id end
  end
  if piece.fills then
    mark(piece.row, 0, { end_row = piece.last, end_col = #line_of(bufnr, piece.last), conceal_lines = '' })
  else
    mark(piece.row, piece.sc, { end_row = piece.last, end_col = piece.ec, conceal = '' })
    if piece.text then
      mark(piece.row, piece.sc, { virt_text = { { piece.text, 'FeyLinkText' } }, virt_text_pos = 'inline' })
    end
  end
end

---Draw a buffer again from its tags
---@param bufnr integer
---@param tags FeyTag[]
function M.apply(bufnr, tags)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local pieces = {}
  local names = { [config.fey_link_tag_name] = true, [config.fey_section_tag_name] = true }
  for _, tag in ipairs(tags) do
    if names[tag.name] and M.is_concealed(tag.key_values) then vim.list_extend(pieces, pieces_of(bufnr, tag)) end
  end
  state[bufnr] = { pieces = pieces, active = {} }
  for i = 1, #pieces do
    draw(bufnr, i)
  end
end

---The cursor moved: draw again the pieces it entered or left
---@param bufnr integer
function M.on_cursor(bufnr)
  local st = state[bufnr]
  if not st or #st.pieces == 0 then return end
  for i, piece in ipairs(st.pieces) do
    local inside = false
    for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
      local row = vim.api.nvim_win_get_cursor(win)[1] - 1
      if row >= piece.row and row <= piece.last then inside = true end
    end
    if inside ~= st.active[i] then draw(bufnr, i) end
  end
end

---Draw a buffer again, after an option changed
---@param bufnr integer
function M.refresh(bufnr)
  if not parse or not vim.api.nvim_buf_is_valid(bufnr) then return end
  local tags = parse(bufnr)
  if tags then M.apply(bufnr, tags) end
end

function M.setup_query(parse_tags)
  parse = parse_tags
  vim.api.nvim_set_hl(0, 'FeyLinkText', { link = 'Underlined', default = true })
  local group = vim.api.nvim_create_augroup('FeyLinkConceal', { clear = true })
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
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = group,
    callback = function() vim.api.nvim_set_hl(0, 'FeyLinkText', { link = 'Underlined', default = true }) end,
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
