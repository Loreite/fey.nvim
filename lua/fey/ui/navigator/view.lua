-- Floating UI for the Fey navigator: a thin pane with the level above, the navigation pane, a preview.
--
--   ╭ ◈ ╮╭ Fey › Headings › * Project A ─╮╭ heading · L3–21 ────────────────╮
--   │ ▫ ││ § * Tasks                 L9 › ││  2 │ (subdued context)           │
--   │ ▫ ││ § * Notes                L15   ││  3 │   * Project A               │
--   ╰───╯╰ h up  l open  ⇥ local … ───────╯╰────────────────────────────────╯
--
-- The navigator has two kinds of level. A document level shows the objects of a Fey file (headings, lists,
-- tables, tags ...). Above it are the levels of the file system: the directories of a hollow, and the
-- hollows themselves with the court on top (see `fey.ui.navigator.levels`). `h` at the top of a document
-- goes up into its directory, and on up the directories to the root of the hollow, then through the
-- hollows above it. `l` goes back down. `H` switches to a level that lists only hollows.
--
-- The navigation pane is the only focusable window. Everything lives in scratch buffers (buftype=nofile,
-- bufhidden=wipe, noswapfile).

local config = require('fey.ui.navigator.config')
local model_mod = require('fey.ui.navigator.model')
local state = require('fey.ui.navigator.state')
local levels = require('fey.ui.navigator.levels')

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
  FeyNavHollow = 'Title',
  FeyNavParent = 'Comment',
  FeyNavParentCurrent = 'Visual',
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

---@param path string
---@return string
local function real(path)
  return vim.uv.fs_realpath(path) or vim.fs.normalize(path)
end

---Icon of a level item
---@param it FeyNavLevelItem
---@return string
local function level_icon(it)
  local icons = config.options.icons
  if it.kind == 'hollow' then return it.court and icons.court or icons.hollow end
  if it.kind == 'dir' then return it.hollow and icons.hollow or icons.dir end
  return icons.file
end

-- ---------------------------------------------------------------------------
-- Session
-- ---------------------------------------------------------------------------

---@class FeyNavTreeFrame
---@field mode 'tree'
---@field loc FeyNavLoc
---@field cursor integer
---@field filter? string
---@field selected_path? string
---@field _items FeyNavLevelItem[]
---@field _view FeyNavLevelItem[]

---@class FeyNavSession
---@field mode 'doc'|'tree'
---@field bufnr? integer         the document of the document levels
---@field src_win integer
---@field model? FeyNavModel
---@field stack FeyNavFrame[]
---@field tframe? FeyNavTreeFrame the current level above the document
---@field tmem table<string, { selected?: string }>  where the cursor was in a level
---@field doc_cache table<integer, { model: FeyNavModel, stack: FeyNavFrame[] }>
---@field loaded table<integer, boolean>  buffers the navigator loaded to show them
---@field jump_opts { cwd?: boolean, tab?: boolean }
---@field par_buf integer
---@field nav_buf integer
---@field prev_buf integer       fey preview (tree-sitter highlighted)
---@field info_buf integer       plain-text preview (category outlines, messages)
---@field par_win? integer
---@field nav_win integer
---@field prev_win integer
---@field augroup integer
---@field prompting boolean
---@field closed boolean
---@field on_close? fun(session: FeyNavSession)
local Session = {}
Session.__index = Session

---@class FeyNavViewOpts
---@field src_win integer
---@field on_close? fun(s: FeyNavSession)
---@field loc? FeyNavLoc      start in a level above the documents
---@field select? string      the path to put the cursor on there
---@field jump_opts? { cwd?: boolean, tab?: boolean }

---@param model FeyNavModel|nil nil starts in a level above the documents
---@param stack FeyNavFrame[]|nil
---@param opts FeyNavViewOpts
---@return FeyNavSession
function M.open(model, stack, opts)
  M.define_highlights()
  local self = setmetatable({
    mode = model and 'doc' or 'tree',
    bufnr = model and model.bufnr or nil,
    src_win = opts.src_win,
    model = model,
    stack = stack or {},
    tmem = {},
    doc_cache = {},
    loaded = {},
    jump_opts = opts.jump_opts or {},
    prompting = false,
    closed = false,
    on_close = opts.on_close,
  }, Session)

  self.nav_buf = scratch_buf('feynav')
  self.par_buf = scratch_buf('feynav')
  self.info_buf = scratch_buf(nil, true)
  self.prev_buf = scratch_buf(nil, true)
  if config.options.preview_filetype then
    vim.bo[self.prev_buf].filetype = 'fey'
  else
    pcall(vim.treesitter.start, self.prev_buf, 'fey')
  end

  local layout = self:layout()
  self.prev_win = api.nvim_open_win(self.info_buf, false, layout.prev)
  if layout.par then self.par_win = api.nvim_open_win(self.par_buf, false, layout.par) end
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

  if self.par_win then
    local pw = vim.wo[self.par_win]
    pw.cursorline = false
    pw.number = false
    pw.relativenumber = false
    pw.signcolumn = 'no'
    pw.foldenable = false
    pw.wrap = false
    pw.scrolloff = 0
    pw.statuscolumn = ''
  end

  if not model then self:goto_loc(opts.loc or { kind = 'hollows' }, opts.select) end

  self:keymaps()
  self:autocmds()
  self:render()
  return self
end

-- Geometry for the windows (outer box = width x height, centered).
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
  local inner_h = math.max(3, height - pad)
  local row = math.max(0, math.floor((lines - height) / 2))
  local col = math.max(0, math.floor((cols - width) / 2))

  local par_out = 0
  if o.show_parent then par_out = math.max(10 + pad, math.min(size(o.parent_width, width), 30 + pad)) end
  local nav_out = math.max(20 + pad, size(o.nav_width, width))
  local prev_out = math.max(10 + pad, width - par_out - nav_out)

  local base = { relative = 'editor', style = 'minimal', border = b, height = inner_h, row = row }
  local layout = {
    border = b,
    nav = vim.tbl_extend('force', base, { width = nav_out - pad, col = col + par_out, zindex = 51 }),
    prev = vim.tbl_extend('force', base, { width = prev_out - pad, col = col + par_out + nav_out, focusable = false, zindex = 50 }),
  }
  if par_out > 0 then
    layout.par = vim.tbl_extend('force', base, { width = par_out - pad, col = col, focusable = false, zindex = 50 })
  end
  return layout
end

function Session:apply_footer(layout)
  if not has_border(layout.border) then
    return
  end
  local k = config.options.keys
  local function key(v)
    v = type(v) == 'table' and v[1] or v
    return (v:gsub('<Tab>', '⇥'):gsub('<CR>', '⏎'):gsub('<C%-(.)>', '^%1'))
  end
  local text
  if self.mode == 'tree' then
    text = string.format(' %s up  %s open  %s jump  %s tab  %s filter  %s hollows ', key(k.back), key(k.enter), key(k.jump),
      key(k.jump_tab), key(k.filter), key(k.hollows))
  else
    text = string.format(' %s up  %s open  %s local  %s jump  %s filter  %s hollows ', key(k.back), key(k.enter),
      key(k.local_root), key(k.jump), key(k.filter), key(k.hollows))
  end
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
  if self.par_win and layout.par then pcall(api.nvim_win_set_config, self.par_win, layout.par) end
  self:apply_footer(layout)
  self:render()
end

---@return FeyNavFrame|FeyNavTreeFrame
function Session:frame()
  if self.mode == 'tree' then return self.tframe end
  return self.stack[#self.stack]
end

---@return FeyNavItem|FeyNavLevelItem|nil
function Session:current()
  local f = self:frame()
  return f._view and f._view[f.cursor] or nil
end

-- ---------------------------------------------------------------------------
-- Levels above the document
-- ---------------------------------------------------------------------------

---Show a level, with the cursor on `select_path` or where it was last time
---@param loc FeyNavLoc
---@param select_path? string
function Session:goto_loc(loc, select_path)
  local frame = { mode = 'tree', loc = loc, cursor = 1, _items = levels.items(loc) }
  state.refresh_view(frame)
  local want = select_path or (self.tmem[levels.key(loc)] or {}).selected
  if want then
    want = real(want)
    for i, it in ipairs(frame._view) do
      if real(it.path) == want then frame.cursor = i end
    end
  end
  local it = frame._view[frame.cursor]
  frame.selected_path = it and it.path or nil
  self.mode = 'tree'
  self.tframe = frame
  self:apply_footer(self:layout())
end

---Open a Fey file as a document level
---@param path string
function Session:open_doc(path)
  local bufnr = vim.fn.bufnr(path)
  local was_loaded = bufnr > 0 and api.nvim_buf_is_loaded(bufnr)
  if bufnr < 1 then bufnr = vim.fn.bufadd(path) end
  vim.fn.bufload(bufnr)
  if not was_loaded then
    self.loaded[bufnr] = true
    vim.bo[bufnr].buflisted = false
  end

  local cached = self.doc_cache[bufnr]
  local model, stack
  if cached and cached.model.changedtick == api.nvim_buf_get_changedtick(bufnr) then
    model, stack = cached.model, cached.stack
  else
    local err
    model, err = model_mod.new(bufnr)
    if not model then return hint(err or 'cannot read this file') end
    stack = state.fresh(model)
  end
  self.bufnr, self.model, self.stack = bufnr, model, stack
  self.mode = 'doc'
  self:apply_footer(self:layout())
  self:render()
end

---Remember the document, so that coming back to it finds the same place
function Session:stash_doc()
  if self.mode == 'doc' and self.bufnr and self.model then
    self.doc_cache[self.bufnr] = { model = self.model, stack = self.stack }
  end
end

---`h`: up a level
function Session:up()
  if self.mode == 'doc' then
    if #self.stack > 1 then
      self.stack[#self.stack] = nil
      return self:render()
    end
    -- the top of a document: into the directory it is in
    local dir = self.bufnr and levels.dir_of_buffer(self.bufnr)
    if not dir then return hint('This buffer is not a file') end
    self:stash_doc()
    self:goto_loc({ kind = 'dir', path = dir }, api.nvim_buf_get_name(self.bufnr))
    return self:render()
  end
  local loc = self.tframe.loc
  local parent = levels.parent_loc(loc)
  if not parent then return hint('This is the top') end
  self:goto_loc(parent, levels.anchor_of(loc))
  self:render()
end

---`H`: the level with only hollows, at the hollow of what is shown
function Session:hollows()
  local path
  if self.mode == 'doc' then
    path = self.bufnr and api.nvim_buf_get_name(self.bufnr) or nil
    if path == '' then path = nil end
    self:stash_doc()
  else
    local loc = self.tframe.loc
    path = loc.kind == 'dir' and loc.path or loc.parent
  end
  local loc, select = levels.hollow_level_for(path)
  self:goto_loc(loc, select)
  self:render()
end

---`l` on an item of a level above the document
function Session:enter_level_item()
  local it = self:current()
  if not it then return end
  local loc = self.tframe.loc
  if it.kind == 'file' then return self:open_doc(it.path) end
  if it.kind == 'dir' then
    self:goto_loc({ kind = 'dir', path = it.path })
    return self:render()
  end
  -- a hollow in a list of hollows: the hollows below it, else its directory
  if it.ok == false then return hint(it.label .. ' is not available') end
  if #levels.hollow_items(it.path) == 0 then return self:enter_hollow_dir(it) end
  self:goto_loc({ kind = 'hollows', parent = it.path }, nil)
  self:render()
  if loc then self.tmem[levels.key(loc)] = { selected = it.path } end
end

---The directory of a hollow (the way back down from the directory level into the hollows above it)
---@param it? FeyNavLevelItem
function Session:enter_hollow_dir(it)
  it = it or self:current()
  if not it or it.kind ~= 'hollow' then return end
  if it.ok == false then return hint(it.label .. ' is not available') end
  local loc = self.tframe.loc
  self:goto_loc({ kind = 'dir', path = it.path })
  self:render()
  if loc then self.tmem[levels.key(loc)] = { selected = it.path } end
end

---Jump to a hollow: its directory, in a new tab and with its working directory as configured
---@param it FeyNavLevelItem
---@param opts { cwd?: boolean, tab?: boolean }
local function jump_hollow(it, opts)
  local id = it.id or require('fey.hollow.tree').id_of(it.path)
  if id then return require('fey.hollow.court').jump(id, opts) end
  local options = require('fey.config').court or {}
  local cwd, tab = opts.cwd, opts.tab
  if cwd == nil then cwd = options.jump_cwd ~= false end
  if tab == nil then tab = options.jump_tab == true end
  if tab then vim.cmd('tabnew') end
  if cwd then vim.cmd((tab and 'tcd ' or 'cd ') .. vim.fn.fnameescape(it.path)) end
  vim.cmd('edit ' .. vim.fn.fnameescape(it.path))
end

---`<CR>` on an item of a level above the document
---@param extra? { cwd?: boolean, tab?: boolean }
function Session:jump_level_item(extra)
  local it = self:current()
  if not it then return end
  local win = self.src_win
  local opts = vim.tbl_extend('force', self.jump_opts, extra or {})
  self:close()
  if it.kind == 'file' then
    if opts.tab then vim.cmd('tabnew') elseif api.nvim_win_is_valid(win) then api.nvim_set_current_win(win) end
    vim.cmd('edit ' .. vim.fn.fnameescape(it.path))
  elseif it.kind == 'dir' and not it.hollow then
    if opts.tab then vim.cmd('tabnew') elseif api.nvim_win_is_valid(win) then api.nvim_set_current_win(win) end
    vim.cmd('edit ' .. vim.fn.fnameescape(it.path))
  else
    jump_hollow(it, opts)
  end
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

function Session:breadcrumb()
  if self.mode == 'tree' then
    local parts = { 'Fey' }
    vim.list_extend(parts, levels.breadcrumb(self.tframe.loc))
    return table.concat(parts, ' › ')
  end
  local parts = { 'Fey' }
  if self.bufnr then
    local name = api.nvim_buf_get_name(self.bufnr)
    if name ~= '' then parts[#parts + 1] = vim.fn.fnamemodify(name, ':t') end
  end
  for i = 2, #self.stack do
    local f = self.stack[i]
    local label = f._anchor and f._anchor.label or (f.anchor and f.anchor.label) or '?'
    label = label:gsub('%s*%(.-%)$', '')
    parts[#parts + 1] = (f.mode == 'local' and '⇥ ' or '') .. truncate(label, 24)
  end
  return table.concat(parts, ' › ')
end

function Session:render_tree()
  local f = self.tframe
  local view = f._view or {}
  local width = api.nvim_win_get_width(self.nav_win)
  local icons = config.options.icons

  local lines, marks = {}, {}
  for i, it in ipairs(view) do
    local icon = level_icon(it)
    local detail = ''
    local has_kids = false
    if it.kind == 'dir' then
      has_kids = true
      detail = it.hollow and 'hollow' or ''
    elseif it.kind == 'hollow' then
      has_kids = it.ok ~= false and #levels.hollow_items(it.path) > 0
      detail = it.ok == false and 'not available' or (it.court and 'court' or '')
    end
    local right = detail .. ' ' .. (has_kids and icons.has_children or ' ')
    local room = math.max(8, math.min(config.options.label_max, width - vim.fn.strdisplaywidth(right) - 5))
    lines[i] = string.format(' %s %s', icon, truncate(it.label, room))
    marks[i] = { icon = icon, detail = detail, has_kids = has_kids, hollow = it.hollow or it.kind == 'hollow', dim = it.ok == false }
  end
  if #lines == 0 then
    if f.filter and f.filter ~= '' then
      lines = { '  No match for "' .. f.filter .. '"' }
    elseif f.loc.kind == 'hollows' then
      lines = { '  No hollows' }
    else
      lines = { '  No Fey files or directories here' }
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
      hl_group = m.hollow and 'FeyNavHollow' or 'FeyNavIcon',
    })
    if m.dim then api.nvim_buf_set_extmark(self.nav_buf, ns, row, 2 + #m.icon, { end_row = row + 1, hl_group = 'FeyNavEmpty' }) end
    api.nvim_buf_set_extmark(self.nav_buf, ns, row, 0, {
      virt_text = {
        { m.detail, 'FeyNavDetail' },
        { ' ' .. (m.has_kids and icons.has_children or ' ') .. ' ', 'FeyNavChildren' },
      },
      virt_text_pos = 'right_align',
    })
  end

  f.cursor = math.max(1, math.min(f.cursor or 1, math.max(1, #view)))
  api.nvim_win_set_cursor(self.nav_win, { f.cursor, 0 })
end

function Session:render_doc()
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
end

---The thin pane: the items of the level above, with the one we came from marked
---@return FeyNavLevelItem[]|FeyNavItem[]|nil items
---@return string|nil anchor path to mark (levels)
---@return integer|nil index row to mark (document levels)
---@return string title
function Session:parent_items()
  if self.mode == 'tree' then
    local parent = levels.parent_loc(self.tframe.loc)
    if not parent then return nil, nil, nil, 'top' end
    local parts = levels.breadcrumb(parent)
    return levels.items(parent), levels.anchor_of(self.tframe.loc), nil, parts[#parts] or ''
  end
  if #self.stack > 1 then
    local prev = self.stack[#self.stack - 1]
    return prev._view, nil, prev.cursor, 'up'
  end
  local dir = self.bufnr and levels.dir_of_buffer(self.bufnr)
  if not dir then return nil, nil, nil, '' end
  return levels.dir_items(dir), api.nvim_buf_get_name(self.bufnr), nil, vim.fs.basename(dir)
end

function Session:render_parent()
  if not self.par_win or not api.nvim_win_is_valid(self.par_win) then return end
  local width = api.nvim_win_get_width(self.par_win)
  local items, anchor, index, title = self:parent_items()
  local lines, mark = {}, nil
  if not items then
    lines = { ' ' }
  else
    for i, it in ipairs(items) do
      local icon = it.kind and (it.range and (config.options.icons[it.kind] or ' ') or level_icon(it)) or ' '
      lines[i] = ' ' .. icon .. ' ' .. truncate(it.label, math.max(4, width - 4))
      if (anchor and it.path and real(it.path) == real(anchor)) or (index and index == i) then mark = i end
    end
  end
  set_lines(self.par_buf, lines)
  api.nvim_buf_clear_namespace(self.par_buf, ns, 0, -1)
  api.nvim_buf_set_extmark(self.par_buf, ns, 0, 0, { end_row = #lines, hl_group = 'FeyNavParent', hl_eol = true })
  if mark then
    api.nvim_buf_set_extmark(self.par_buf, ns, mark - 1, 0, {
      end_row = mark,
      hl_group = 'FeyNavParentCurrent',
      hl_eol = true,
      priority = 150,
    })
  end
  pcall(api.nvim_win_set_cursor, self.par_win, { math.max(1, math.min(mark or 1, #lines)), 0 })
  if has_border(border()) then
    pcall(api.nvim_win_set_config, self.par_win, {
      title = { { ' ' .. truncate(title or '', math.max(4, width - 2)) .. ' ', 'FloatTitle' } },
      title_pos = 'left',
    })
  end
end

function Session:render()
  if self.closed then
    return
  end
  local f = self:frame()
  local width = api.nvim_win_get_width(self.nav_win)
  if self.mode == 'tree' then self:render_tree() else self:render_doc() end

  local b = border()
  if has_border(b) then
    local title = ' ' .. truncate(self:breadcrumb(), math.max(10, width - 4)) .. ' '
    local chunks = { { title, 'FloatTitle' } }
    if f.filter and f.filter ~= '' then
      chunks[#chunks + 1] = { ' /' .. f.filter .. ' ', 'FeyNavFilter' }
    end
    pcall(api.nvim_win_set_config, self.nav_win, { title = chunks, title_pos = 'left' })
  end

  self:render_parent()
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

---What a hollow is, for the preview
---@param it FeyNavLevelItem
---@return string[] lines
local function hollow_info(it)
  local tree = require('fey.hollow.tree')
  local lines = { '' }
  local function add(label, value) lines[#lines + 1] = string.format('  %-9s %s', label, value) end
  local id = it.id or tree.id_of(it.path)
  if id then add('id', id) end
  add('path', it.path)
  if it.ok == false or not tree.is_hollow(it.path) then
    add('state', 'not available')
    return lines
  end
  local ok, count = pcall(function()
    local vault = require('fey.vault').open(it.path)
    if vault and vault:open() then return vault:query('SELECT COUNT(*) AS n FROM files')[1].n end
  end)
  add('vault', ok and count and (count .. ' files') or 'not indexed')
  add('below', #tree.children(it.path) .. ' hollows')
  add('merge', tree.settings(it.path).merge and 'in merged views' or 'out of merged views')
  if it.court then add('court', 'the top of the tree') end
  return lines
end

function Session:preview_level()
  local it = self:current()
  if not it then
    return self:show_info('Preview', { '', '  Nothing here.' })
  end
  local o = config.options

  if it.kind == 'file' then
    local lines = vim.fn.readfile(it.path, '', o.preview_max_lines)
    vim.w[self.prev_win].fey_nav_offset = 0
    self:show_buf(self.prev_buf, true)
    vim.bo[self.prev_buf].modifiable = true
    api.nvim_buf_set_lines(self.prev_buf, 0, -1, false, lines)
    api.nvim_buf_clear_namespace(self.prev_buf, ns, 0, -1)
    self:preview_title('file · ' .. it.label)
    api.nvim_win_call(self.prev_win, function()
      vim.fn.winrestview({ topline = 1, lnum = 1, col = 0 })
    end)
    return
  end

  local lines, hls = {}, {}
  if it.kind == 'hollow' or it.hollow then
    lines = hollow_info(it)
    lines[#lines + 1] = ''
  end
  local listing = it.kind == 'hollow' and levels.hollow_items(it.path) or levels.dir_items(it.path)
  if it.kind == 'hollow' and #listing == 0 then listing = levels.dir_items(it.path) end
  for _, child in ipairs(listing) do
    lines[#lines + 1] = ' ' .. level_icon(child) .. ' ' .. child.label
    hls[#hls + 1] = { #lines - 1, 1, 1 + #level_icon(child), child.kind == 'hollow' and 'FeyNavHollow' or 'FeyNavIcon' }
  end
  if #listing == 0 then lines[#lines + 1] = '  (empty)' end
  return self:show_info((it.kind == 'hollow' and 'hollow · ' or 'directory · ') .. it.label, lines, hls)
end

function Session:preview()
  if self.mode == 'tree' then return self:preview_level() end
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
  local it = f._view[f.cursor]
  if self.mode == 'tree' then
    f.selected_path = it.path
    self.tmem[levels.key(f.loc)] = { selected = it.path }
  else
    f.selected = model_mod.to_ref(it)
  end
  api.nvim_win_set_cursor(self.nav_win, { f.cursor, 0 })
  self:render_parent()
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
  if self.mode == 'tree' then return self:enter_level_item() end
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
  if self.mode == 'tree' then
    local cur = self:current()
    if cur and cur.kind == 'hollow' then return self:enter_hollow_dir(cur) end
    return hint('Only objects of a document have a local view')
  end
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
  self:up()
end

---@param extra? { cwd?: boolean, tab?: boolean }
function Session:jump(extra)
  if self.mode == 'tree' then return self:jump_level_item(extra) end
  local it = self:current()
  if not it then
    return
  end
  if it.kind == 'category' then
    return self:enter()
  end
  local win, row, col = self.src_win, it.range[1] + 1, it.range[2]
  local bufnr = self.bufnr
  -- the document is the one the user is in, or a file that was only loaded to look at it
  local shown = api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == bufnr
  if not shown then
    self.loaded[bufnr] = nil
    vim.bo[bufnr].buflisted = true
  end
  self:close()
  if api.nvim_win_is_valid(win) then
    api.nvim_set_current_win(win)
    if not shown then api.nvim_win_set_buf(win, bufnr) end
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
    if self.mode == 'tree' then
      f.cursor = 1
      for i, it in ipairs(f._view) do
        if current and it.path == current.path then f.cursor = i end
      end
      local it = f._view[f.cursor]
      f.selected_path = it and it.path or nil
    else
      f.selected = current and model_mod.to_ref(current) or f.selected
      state.place_cursor(f)
    end
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
  if self.mode == 'doc' and self.bufnr and api.nvim_buf_is_valid(self.bufnr) and self.model then
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
  for _, win in ipairs({ self.nav_win, self.prev_win, self.par_win }) do
    if win and api.nvim_win_is_valid(win) then
      pcall(api.nvim_win_close, win, true)
    end
  end
  -- stop the highlighters while their buffers are still whole; the one that tears itself down when its
  -- buffer is deleted calls into a buffer that is going away and raises
  for _, buf in ipairs({ self.prev_buf, self.info_buf }) do
    if buf and api.nvim_buf_is_valid(buf) then pcall(vim.treesitter.stop, buf) end
  end
  for _, buf in ipairs({ self.nav_buf, self.prev_buf, self.info_buf, self.par_buf }) do
    if buf and api.nvim_buf_is_valid(buf) then
      pcall(api.nvim_buf_delete, buf, { force = true })
    end
  end
  -- files that were only loaded to look at them
  for buf in pairs(self.loaded) do
    if api.nvim_buf_is_valid(buf) and #vim.fn.win_findbuf(buf) == 0 then
      pcall(vim.treesitter.stop, buf)
      pcall(api.nvim_buf_delete, buf, {})
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
  end, 'open')
  map(k.back, function()
    self:up()
  end, 'up a level')
  map(k.local_root, function()
    self:enter_local()
  end, 'contents as local root')
  map(k.jump, function()
    self:jump()
  end, 'jump')
  map(k.jump_tab, function()
    self:jump({ tab = true })
  end, 'jump in a new tab')
  map(k.hollows, function()
    self:hollows()
  end, 'hollows')
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
