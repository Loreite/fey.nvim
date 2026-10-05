-- Dual-pane floating UI for the Fey navigator.
--
--   ╭ Fey › Headings › * Project A ─╮╭ heading · L3–21 ────────────────╮
--   │ § * Tasks                 L9 › ││  2 │ (subdued context)           │
--   │ § * Notes                L15   ││  3 │   * Project A               │
--   ╰ h back  l open  ⇥ local … ────╯╰────────────────────────────────╯
--
-- The navigation pane is the only focusable window. Everything lives in
-- scratch buffers (buftype=nofile, bufhidden=wipe, noswapfile).

local config = require('fey.ui.navigator.config')
local model_mod = require('fey.ui.navigator.model')
local state = require('fey.ui.navigator.state')

local api = vim.api
local ns = api.nvim_create_namespace('fey_navigator')

local M = {}

local HL = {
  FeyNavIcon = 'Special',
  FeyNavCategory = 'Title',
  FeyNavDetail = 'Comment',
  FeyNavChildren = 'Special',
  FeyNavCount = 'Number',
  FeyNavEmpty = 'Comment',
  FeyNavContext = 'Comment',
  FeyNavTarget = 'Visual',
  FeyNavFilter = 'Search',
}

function M.define_highlights()
  for name, link in pairs(HL) do
    api.nvim_set_hl(0, name, { link = link, default = true })
  end
end

-- `hidden`: the two preview buffers take turns in the preview window, so
-- they must survive being hidden; close() wipes them explicitly.
local function scratch_buf(ft, hidden)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = hidden and 'hide' or 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].undolevels = -1
  if ft then
    vim.bo[buf].filetype = ft
  end
  return buf
end

local function set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

local function border()
  local b = config.options.border
  if b then
    return b
  end
  local ok, wb = pcall(function()
    return vim.o.winborder
  end)
  if ok and wb and wb ~= '' then
    return wb
  end
  return 'rounded'
end

local function has_border(b)
  return b ~= 'none' and b ~= ''
end

local function truncate(s, max)
  if vim.fn.strdisplaywidth(s) <= max then
    return s
  end
  return vim.fn.strcharpart(s, 0, math.max(1, max - 1)) .. '…'
end

local function rows_label(range)
  local a, b = range[1] + 1, model_mod.last_row(range) + 1
  return a == b and ('L' .. a) or string.format('L%d–%d', a, b)
end

local function hint(msg)
  api.nvim_echo({ { msg, 'Comment' } }, false, {})
end

-- ---------------------------------------------------------------------------
-- Session
-- ---------------------------------------------------------------------------

---@class FeyNavSession
---@field bufnr integer          source buffer
---@field src_win integer
---@field model FeyNavModel
---@field stack FeyNavFrame[]
---@field nav_buf integer
---@field prev_buf integer       fey preview (tree-sitter highlighted)
---@field info_buf integer       plain-text preview (category outlines, messages)
---@field nav_win integer
---@field prev_win integer
---@field augroup integer
---@field prompting boolean
---@field closed boolean
---@field on_close? fun(session: FeyNavSession)
local Session = {}
Session.__index = Session

---@param model FeyNavModel
---@param stack FeyNavFrame[]
---@param opts { src_win: integer, on_close?: fun(s: FeyNavSession) }
---@return FeyNavSession
function M.open(model, stack, opts)
  M.define_highlights()
  local self = setmetatable({
    bufnr = model.bufnr,
    src_win = opts.src_win,
    model = model,
    stack = stack,
    prompting = false,
    closed = false,
    on_close = opts.on_close,
  }, Session)

  self.nav_buf = scratch_buf('feynav')
  self.info_buf = scratch_buf(nil, true)
  self.prev_buf = scratch_buf(nil, true)
  if config.options.preview_filetype then
    vim.bo[self.prev_buf].filetype = 'fey'
  else
    pcall(vim.treesitter.start, self.prev_buf, 'fey')
  end

  local layout = self:layout()
  self.prev_win = api.nvim_open_win(self.info_buf, false, layout.prev)
  self.nav_win = api.nvim_open_win(self.nav_buf, true, layout.nav)
  self:apply_footer(layout)

  local wo = vim.wo[self.nav_win]
  wo.cursorline = true
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = 'no'
  wo.foldenable = false
  wo.wrap = false
  wo.scrolloff = 2
  wo.statuscolumn = ''

  local po = vim.wo[self.prev_win]
  po.cursorline = false
  po.relativenumber = false
  po.signcolumn = 'no'
  po.foldenable = false
  po.wrap = false
  po.scrolloff = 0

  self:keymaps()
  self:autocmds()
  self:render()
  return self
end

-- Geometry for both windows (outer box = width x height, centered).
function Session:layout()
  local o = config.options
  local cols, lines = vim.o.columns, vim.o.lines - vim.o.cmdheight - 1
  local function size(v, total)
    return v <= 1 and math.floor(total * v) or math.floor(v)
  end
  local b = border()
  local pad = has_border(b) and 2 or 0
  local width = math.max(40, math.min(size(o.width, cols), cols - 2))
  local height = math.max(8, math.min(size(o.height, lines), lines - 2))
  local nav_w = math.max(20, size(o.nav_width, width) - pad)
  local prev_w = math.max(10, width - nav_w - 2 * pad)
  local inner_h = math.max(3, height - pad)
  local row = math.max(0, math.floor((lines - height) / 2))
  local col = math.max(0, math.floor((cols - width) / 2))
  local base = { relative = 'editor', style = 'minimal', border = b, height = inner_h, row = row }
  return {
    border = b,
    nav = vim.tbl_extend('force', base, { width = nav_w, col = col, zindex = 51 }),
    prev = vim.tbl_extend('force', base, { width = prev_w, col = col + nav_w + pad, focusable = false, zindex = 50 }),
  }
end

function Session:apply_footer(layout)
  if not has_border(layout.border) then
    return
  end
  local k = config.options.keys
  local function key(v)
    v = type(v) == 'table' and v[1] or v
    return (v:gsub('<Tab>', '⇥'):gsub('<CR>', '⏎'))
  end
  local text = string.format(' %s back  %s open  %s local  %s jump  %s filter ', key(k.back), key(k.enter),
    key(k.local_root), key(k.jump), key(k.filter))
  -- footer needs nvim 0.10+
  pcall(api.nvim_win_set_config, self.nav_win, { footer = { { text, 'FeyNavDetail' } }, footer_pos = 'center' })
end

function Session:relayout()
  if self.closed then
    return
  end
  local layout = self:layout()
  pcall(api.nvim_win_set_config, self.prev_win, layout.prev)
  pcall(api.nvim_win_set_config, self.nav_win, layout.nav)
  self:apply_footer(layout)
  self:render()
end

---@return FeyNavFrame
function Session:frame()
  return self.stack[#self.stack]
end

---@return FeyNavItem|nil
function Session:current()
  local f = self:frame()
  return f._view and f._view[f.cursor] or nil
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

function Session:breadcrumb()
  local parts = { 'Fey' }
  for i = 2, #self.stack do
    local f = self.stack[i]
    local label = f._anchor and f._anchor.label or (f.anchor and f.anchor.label) or '?'
    label = label:gsub('%s*%(.-%)$', '')
    parts[#parts + 1] = (f.mode == 'local' and '⇥ ' or '') .. truncate(label, 24)
  end
  return table.concat(parts, ' › ')
end

function Session:render()
  if self.closed then
    return
  end
  local o = config.options
  local f = self:frame()
  local view = f._view or {}
  local icons = o.icons
  local width = api.nvim_win_get_width(self.nav_win)

  local lines, marks = {}, {}
  for i, it in ipairs(view) do
    local icon = icons[it.kind] or ' '
    local detail, has_kids
    if it.kind == 'category' then
      detail = tostring(it.count)
      has_kids = true
    else
      detail = rows_label(it.range)
      has_kids = #self.model:children(it) > 0
    end
    local right = detail .. ' ' .. (has_kids and icons.has_children or ' ')
    local room = math.max(8, math.min(o.label_max, width - vim.fn.strdisplaywidth(right) - 5))
    local text = string.format(' %s %s', icon, truncate(it.label, room))
    lines[i] = text
    marks[i] = { icon = icon, right = right, kind = it.kind, has_kids = has_kids, detail = detail }
  end
  if #lines == 0 then
    if f.filter and f.filter ~= '' then
      lines = { '  No match for "' .. f.filter .. '"' }
    elseif f.mode == 'root' then
      lines = { '  No Fey objects in this buffer' }
    else
      lines = { '  (empty)' }
    end
  end

  set_lines(self.nav_buf, lines)
  api.nvim_buf_clear_namespace(self.nav_buf, ns, 0, -1)
  if #view == 0 then
    api.nvim_buf_set_extmark(self.nav_buf, ns, 0, 0, { end_row = 1, hl_group = 'FeyNavEmpty', hl_eol = true })
  end
  for i, m in ipairs(marks) do
    local row = i - 1
    api.nvim_buf_set_extmark(self.nav_buf, ns, row, 1, {
      end_col = 1 + #m.icon,
      hl_group = m.kind == 'category' and 'FeyNavCategory' or 'FeyNavIcon',
    })
    if m.kind == 'category' then
      api.nvim_buf_set_extmark(self.nav_buf, ns, row, 2 + #m.icon, { end_row = row + 1, hl_group = 'FeyNavCategory' })
    end
    api.nvim_buf_set_extmark(self.nav_buf, ns, row, 0, {
      virt_text = {
        { m.detail, m.kind == 'category' and 'FeyNavCount' or 'FeyNavDetail' },
        { ' ' .. (m.has_kids and config.options.icons.has_children or ' ') .. ' ', 'FeyNavChildren' },
      },
      virt_text_pos = 'right_align',
    })
  end

  f.cursor = math.max(1, math.min(f.cursor or 1, math.max(1, #view)))
  api.nvim_win_set_cursor(self.nav_win, { f.cursor, 0 })

  local b = border()
  if has_border(b) then
    local title = ' ' .. truncate(self:breadcrumb(), math.max(10, width - 4)) .. ' '
    local chunks = { { title, 'FloatTitle' } }
    if f.filter and f.filter ~= '' then
      chunks[#chunks + 1] = { ' /' .. f.filter .. ' ', 'FeyNavFilter' }
    end
    pcall(api.nvim_win_set_config, self.nav_win, { title = chunks, title_pos = 'left' })
  end

  self:preview()
  self:save()
end

-- Swap the preview window between the fey buffer and the plain info buffer.
function Session:show_buf(buf, fey_mode)
  if api.nvim_win_get_buf(self.prev_win) ~= buf then
    api.nvim_win_set_buf(self.prev_win, buf)
  end
  local wo = vim.wo[self.prev_win]
  wo.number = fey_mode
  wo.statuscolumn = fey_mode and '%=%{v:virtnum ? "" : v:lnum + w:fey_nav_offset} ' or ''
  wo.wrap = not fey_mode
end

function Session:preview_title(text)
  if has_border(border()) then
    pcall(api.nvim_win_set_config, self.prev_win, { title = { { ' ' .. text .. ' ', 'FloatTitle' } }, title_pos = 'left' })
  end
end

function Session:show_info(title, lines, hls)
  self:show_buf(self.info_buf, false)
  set_lines(self.info_buf, lines)
  api.nvim_buf_clear_namespace(self.info_buf, ns, 0, -1)
  for _, h in ipairs(hls or {}) do
    api.nvim_buf_set_extmark(self.info_buf, ns, h[1], h[2], { end_row = h[1], end_col = h[3], hl_group = h[4] })
  end
  self:preview_title(title)
  api.nvim_win_set_cursor(self.prev_win, { 1, 0 })
end

function Session:preview()
  local it = self:current()
  if not it then
    return self:show_info('Preview', { '', '  Nothing selected.' })
  end

  if it.kind == 'category' then
    local lines, hls = {}, {}
    for i, child in ipairs(self.model:children(it)) do
      local icon = config.options.icons[child.kind] or ' '
      local det = string.format('%6s', rows_label(child.range))
      local prefix = ' ' .. det .. '  ' .. icon .. ' '
      lines[i] = prefix .. child.label
      hls[#hls + 1] = { i - 1, 0, 1 + #det, 'FeyNavDetail' }
      hls[#hls + 1] = { i - 1, #prefix - #icon - 1, #prefix - 1, 'FeyNavIcon' }
    end
    return self:show_info(string.format('%s · %d', it.label, it.count or #lines), lines, hls)
  end

  local o = config.options
  local total = api.nvim_buf_line_count(self.bufnr)
  local sr = it.range[1]
  local last = model_mod.last_row(it.range)
  local ctx = o.context_lines
  local first = math.max(0, sr - ctx)
  local shown_last = math.min(last, sr + o.preview_max_lines - 1)
  local truncated = last - shown_last
  local stop = truncated > 0 and shown_last or math.min(total - 1, last + ctx)

  local lines = api.nvim_buf_get_lines(self.bufnr, first, stop + 1, false)
  if truncated > 0 then
    lines[#lines + 1] = string.format('… %d more line%s', truncated, truncated == 1 and '' or 's')
  end

  vim.w[self.prev_win].fey_nav_offset = first -- before 'statuscolumn' reads it
  self:show_buf(self.prev_buf, true)
  vim.bo[self.prev_buf].modifiable = true
  api.nvim_buf_set_lines(self.prev_buf, 0, -1, false, lines)

  api.nvim_buf_clear_namespace(self.prev_buf, ns, 0, -1)
  local function subdue(a, b) -- preview rows [a, b)
    if b > a then
      api.nvim_buf_set_extmark(self.prev_buf, ns, a, 0, {
        end_row = b,
        end_col = 0,
        hl_group = 'FeyNavContext',
        hl_eol = true,
        priority = 200, -- above tree-sitter highlights (100)
      })
    end
  end
  local target_top = sr - first
  local target_bot = shown_last - first -- inclusive
  subdue(0, target_top)
  subdue(target_bot + 1, #lines)

  -- Inline objects (tags, rows, ...) do not own their whole line: mark the
  -- exact span so it stands out from the surrounding text.
  local _, sc, er, ec = unpack(it.range)
  if sc > 0 or (er == sr and ec > 0) then
    local end_row = math.min(er, shown_last) - first
    local end_col = er <= shown_last and ec or 0
    pcall(api.nvim_buf_set_extmark, self.prev_buf, ns, target_top, sc, {
      end_row = end_row,
      end_col = end_col,
      hl_group = 'FeyNavTarget',
      priority = 150,
    })
  end

  self:preview_title(string.format('%s · %s', it.kind, rows_label(it.range)))
  api.nvim_win_call(self.prev_win, function()
    vim.fn.winrestview({ topline = 1, lnum = math.min(#lines, target_top + 1), col = 0 })
  end)
end

-- ---------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------

function Session:select(idx)
  local f = self:frame()
  local n = #(f._view or {})
  if n == 0 then
    return
  end
  f.cursor = math.max(1, math.min(idx, n))
  f.selected = model_mod.to_ref(f._view[f.cursor])
  api.nvim_win_set_cursor(self.nav_win, { f.cursor, 0 })
  self:preview()
  self:save()
end

function Session:move(delta)
  self:select(self:frame().cursor + delta)
end

---@param mode 'children'|'local'
---@param item FeyNavItem
function Session:push(mode, item)
  local frame = { mode = mode, anchor = model_mod.to_ref(item), _anchor = item, cursor = 1 }
  state.load(self.model, frame)
  state.place_cursor(frame)
  self:frame().selected = model_mod.to_ref(item)
  self.stack[#self.stack + 1] = frame
  self:render()
end

function Session:enter()
  local it = self:current()
  if not it then
    return
  end
  if #self.model:children(it) == 0 then
    if it.kind ~= 'category' and #self.model:local_children(it) > 0 then
      hint('No nested ' .. it.kind .. 's here; ' .. config.options.keys.local_root .. ' shows its contents')
    else
      hint('Nothing below this ' .. it.kind)
    end
    return
  end
  self:push('children', it)
end

function Session:enter_local()
  local it = self:current()
  if not it then
    return
  end
  if it.kind == 'category' then
    return self:enter()
  end
  if #self.model:local_children(it) == 0 then
    return hint('This ' .. it.kind .. ' contains no text objects')
  end
  self:push('local', it)
end

function Session:back()
  if #self.stack <= 1 then
    return
  end
  self.stack[#self.stack] = nil
  self:render()
end

function Session:jump()
  local it = self:current()
  if not it then
    return
  end
  if it.kind == 'category' then
    return self:enter()
  end
  local win, row, col = self.src_win, it.range[1] + 1, it.range[2]
  self:close()
  if api.nvim_win_is_valid(win) then
    api.nvim_set_current_win(win)
    pcall(api.nvim_win_set_cursor, win, { row, col })
    vim.cmd('normal! zv')
  end
end

function Session:filter()
  local f = self:frame()
  self.prompting = true
  vim.ui.input({ prompt = 'Filter: ', default = f.filter or '' }, function(input)
    self.prompting = false
    if self.closed then
      return
    end
    if api.nvim_win_is_valid(self.nav_win) then
      api.nvim_set_current_win(self.nav_win)
    end
    if input == nil then
      return -- cancelled: keep the current filter
    end
    local current = self:current()
    f.filter = input ~= '' and input or nil
    state.refresh_view(f)
    f.selected = current and model_mod.to_ref(current) or f.selected
    state.place_cursor(f)
    self:render()
  end)
end

function Session:scroll(key)
  local keys = api.nvim_replace_termcodes(key, true, false, true)
  api.nvim_win_call(self.prev_win, function()
    vim.cmd('normal! ' .. keys)
  end)
end

function Session:save()
  if api.nvim_buf_is_valid(self.bufnr) then
    state.save(self.bufnr, self.stack, self.model.changedtick)
  end
end

function Session:close()
  if self.closed then
    return
  end
  self:save()
  self.closed = true
  pcall(api.nvim_del_augroup_by_id, self.augroup)
  for _, win in ipairs({ self.nav_win, self.prev_win }) do
    if win and api.nvim_win_is_valid(win) then
      pcall(api.nvim_win_close, win, true)
    end
  end
  for _, buf in ipairs({ self.nav_buf, self.prev_buf, self.info_buf }) do
    if buf and api.nvim_buf_is_valid(buf) then
      pcall(api.nvim_buf_delete, buf, { force = true })
    end
  end
  if self.src_win and api.nvim_win_is_valid(self.src_win) then
    pcall(api.nvim_set_current_win, self.src_win)
  end
  if self.on_close then
    self.on_close(self)
  end
end

-- ---------------------------------------------------------------------------
-- Keymaps & autocmds
-- ---------------------------------------------------------------------------

function Session:keymaps()
  local k = config.options.keys
  local function map(lhs, fn, desc)
    for _, l in ipairs(type(lhs) == 'table' and lhs or { lhs }) do
      vim.keymap.set('n', l, fn, { buffer = self.nav_buf, nowait = true, silent = true, desc = 'Fey navigator: ' .. desc })
    end
  end
  map(k.down, function()
    self:move(vim.v.count1)
  end, 'next')
  map(k.up, function()
    self:move(-vim.v.count1)
  end, 'previous')
  map(k.enter, function()
    self:enter()
  end, 'open children')
  map(k.back, function()
    self:back()
  end, 'back')
  map(k.local_root, function()
    self:enter_local()
  end, 'contents as local root')
  map(k.jump, function()
    self:jump()
  end, 'jump to object')
  map(k.filter, function()
    self:filter()
  end, 'filter')
  map(k.scroll_up, function()
    self:scroll('<C-u>')
  end, 'scroll preview up')
  map(k.scroll_down, function()
    self:scroll('<C-d>')
  end, 'scroll preview down')
  map(k.close, function()
    self:close()
  end, 'close')
end

function Session:autocmds()
  self.augroup = api.nvim_create_augroup('FeyNavigator' .. self.nav_buf, { clear = true })
  -- other motions (gg, G, mouse, search) still pick the row
  api.nvim_create_autocmd('CursorMoved', {
    group = self.augroup,
    buffer = self.nav_buf,
    callback = function()
      local row = api.nvim_win_get_cursor(self.nav_win)[1]
      if row ~= self:frame().cursor then
        self:select(row)
      end
    end,
  })
  api.nvim_create_autocmd('WinLeave', {
    group = self.augroup,
    buffer = self.nav_buf,
    callback = function()
      vim.schedule(function()
        if not self.closed and not self.prompting and api.nvim_get_current_win() ~= self.nav_win then
          self:close()
        end
      end)
    end,
  })
  api.nvim_create_autocmd('VimResized', {
    group = self.augroup,
    callback = function()
      self:relayout()
    end,
  })
  api.nvim_create_autocmd('BufWipeout', {
    group = self.augroup,
    buffer = self.nav_buf,
    callback = function()
      vim.schedule(function()
        self:close()
      end)
    end,
  })
end

M.Session = Session
return M
