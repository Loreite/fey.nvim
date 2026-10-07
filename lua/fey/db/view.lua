-- The database view: a VisiData style table in a scratch buffer.
--
-- The buffer only ever holds what is on screen. Rows and columns are virtual: the
-- view packs as many logical rows as fit the window height (a logical row may span
-- several lines when `row_height` > 1) and as many columns as fit its width, starting
-- at `left`. The first `freeze` columns are pinned and never scroll. The cursor is a
-- logical cell (`cur`); the Neovim cursor is only placed on it.
local Fuzzy = require('fey.ui.fuzzy')
local FilterUI = require('fey.db.filter_ui')
local Model = require('fey.db.model')
local V = require('fey.query.values')
local ops = require('fey.query.ops')
local source_edit = require('fey.db.source_edit')
local store = require('fey.db.store')
local text = require('fey.db.text')

local ns = vim.api.nvim_create_namespace('fey_db')
local dw = text.width

---@class FeyDbView
---@field vault FeyVault
---@field name string
---@field base table
---@field view table the active view settings
---@field vi integer index of the active view
---@field model FeyDbModel
---@field bufnr integer
---@field cur { row: integer, col: integer }
---@field top integer first entry shown
---@field left integer first scrolling column shown
---@field history table[]
---@field future table[]
local View = {}
View.__index = View

local M = {}

---@type table<integer, FeyDbView>
local instances = {}
M.instances = instances

local SEP, PIN_SEP = ' │ ', ' ┃ '
local ROW_HEIGHTS = { 1, 2, 3, 4, 6 }

local function define_highlights()
  local function set(name, def)
    def.default = true
    vim.api.nvim_set_hl(0, name, def)
  end
  set('FeyDbTitle', { link = 'Title' })
  set('FeyDbTab', { link = 'TabLineSel' })
  set('FeyDbHeader', { link = 'TabLine' })
  set('FeyDbHeaderCur', { link = 'TabLineSel' })
  set('FeyDbSep', { link = 'Comment' })
  set('FeyDbRow', { link = 'CursorLine' })
  set('FeyDbCell', { link = 'Visual' })
  set('FeyDbGroup', { link = 'Special' })
  set('FeyDbSummary', { link = 'Statement' })
  set('FeyDbStatus', { link = 'StatusLine' })
  set('FeyDbMsg', { link = 'WarningMsg' })
  set('FeyDbNull', { link = 'NonText' })
end

---The vault a row came from (the vault of the view for rows that do not say)
---@param self FeyDbView
---@param row any
---@return FeyVault
local function row_vault(self, row) return require('fey.query.pages').vault_of(row) or self.vault end

---@param row any
---@return string|nil
local function row_path(row)
  if row == nil then return nil end
  local file = ops.get(row, 'file')
  local p = V.is_object(file) and ops.get(file, 'path')
  return type(p) == 'string' and p or nil
end

---Path and vault together: a path alone is not unique over several hollows
---@param row any
---@return string|nil
local function row_key(row)
  local path = row_path(row)
  if not path then return nil end
  local vault = require('fey.query.pages').vault_of(row)
  return (vault and vault.root or '') .. '\0' .. path
end

---@param spec any
---@return string
local function scope_text(spec)
  if type(spec) == 'table' then return table.concat(spec, ' ') end
  return spec or 'current'
end

-- State -------------------------------------------------------------------------------------

function View:sync_refs()
  self.vi = math.min(math.max(self.vi, 1), #self.base.views)
  self.view = self.base.views[self.vi]
  self.model.base = self.base
end

---@return FeyDbResult
function View:result()
  local res = self.model:compute(self.view)
  if res ~= self._res then
    self._res = res
    self.auto_w = {}
    self.summary_cache = {}
    self.rows = res.rows
    local entries, entry_of = {}, {}
    local gi = 1
    for i, row in ipairs(res.rows) do
      local g = res.groups and res.groups[gi]
      if g and g.first == i then
        entries[#entries + 1] = { kind = 'group', key = g.key, count = g.count }
        gi = gi + 1
      end
      entries[#entries + 1] = { kind = 'row', row = row, index = i }
      entry_of[i] = #entries
    end
    self.entries, self.entry_of_row = entries, entry_of
  end
  return res
end

---@param col table
---@return string
function View:col_title(col)
  if col.display and col.display ~= '' then return col.display end
  for _, p in ipairs(self.base.properties or {}) do
    if p.name == col.prop and p.display and p.display ~= '' then return p.display end
  end
  return col.prop
end

---@param ci integer
---@return integer
function View:auto_width(ci)
  local col = self.view.columns[ci]
  local cached = self.auto_w[col.prop]
  if cached then return cached end
  local get = self.model:getter(col.prop)
  local w = dw(self:col_title(col)) + 3
  for i = 1, math.min(#self.rows, 100) do
    for _, item in ipairs(text.cell_items(get(self.rows[i]))) do
      w = math.max(w, dw(item))
    end
  end
  w = math.min(math.max(w, 6), 32)
  self.auto_w[col.prop] = w
  return w
end

---@param msg string
---@param warn? boolean
function View:msg(msg, warn)
  self.message = { text = msg, warn = warn }
end

-- Rendering ------------------------------------------------------------------------------------

---@param v any
local function summary_text(v)
  if V.is_null(v) then return '' end
  if type(v) == 'number' then
    if v % 1 == 0 then return ('%d'):format(v) end
    return (('%.2f'):format(v):gsub('0+$', ''):gsub('%.$', ''))
  end
  return ops.tostring(v)
end

local SUMMARY_SHORT = {
  count = 'n', filled = 'filled', empty = 'empty', unique = 'uniq', sum = 'Σ', average = 'avg', median = 'med',
  min = 'min', max = 'max', range = 'range', stddev = 'σ', earliest = '⇤', latest = '⇥', checked = '✓', unchecked = '✗',
}

function View:render()
  local win = vim.fn.bufwinid(self.bufnr)
  if win == -1 or not vim.api.nvim_buf_is_valid(self.bufnr) then return end
  self.win = win

  local W = vim.api.nvim_win_get_width(win)
  local H = vim.api.nvim_win_get_height(win)
  local view = self.view
  local cols = view.columns
  local res = self:result()
  local rows = self.rows

  self.cur.col = math.min(math.max(self.cur.col, 1), math.max(#cols, 1))
  self.cur.row = math.min(math.max(self.cur.row, 1), math.max(#rows, 1))

  -- columns ---------------------------------------------------------------------------
  local freeze = math.min(math.max(view.freeze or 1, 0), #cols)
  local widths = {}
  for i = 1, #cols do
    widths[i] = math.min(cols[i].width or self:auto_width(i), math.max(W - 6, 4))
  end

  ---@param left integer
  ---@return integer[]
  local function fit(left)
    local vis, used = {}, 1
    for c = 1, freeze do
      if #vis > 0 and used + SEP:len() + widths[c] > W then break end
      vis[#vis + 1] = c
      used = used + widths[c] + (#vis > 1 and 3 or 0)
    end
    for c = math.max(left, freeze + 1), #cols do
      if used + 3 + widths[c] > W and c > math.max(left, freeze + 1) then break end
      vis[#vis + 1] = c
      used = used + widths[c] + (#vis > 1 and 3 or 0)
    end
    return vis
  end

  self.left = math.min(math.max(self.left, freeze + 1), math.max(#cols, freeze + 1))
  if self.cur.col > freeze then
    if self.cur.col < self.left then self.left = self.cur.col end
    while self.left < self.cur.col and not vim.tbl_contains(fit(self.left), self.cur.col) do
      self.left = self.left + 1
    end
  end
  local vis = fit(self.left)

  local has_summary = false
  for _, c in ipairs(cols) do
    if c.summary and c.summary ~= '' then has_summary = true end
  end
  local avail = math.max(H - 3 - 1 - (has_summary and 1 or 0), 1)
  local multi = (view.row_height or 1) > 1

  -- lines ------------------------------------------------------------------------------
  local lines, marks = {}, {}
  local function mark(line, s, e, group, prio)
    marks[#marks + 1] = { line, s, e, group, prio }
  end

  ---@param cells table<integer, { text: string, right?: boolean }>
  ---@return string line
  ---@return table<integer, { [1]: integer, [2]: integer }> spans
  ---@return { [1]: integer, [2]: integer }[] seps
  local function build_line(cells)
    local parts, pos, spans, seps = { ' ' }, 1, {}, {}
    for k, c in ipairs(vis) do
      if k > 1 then
        local sep = (vis[k - 1] <= freeze and c > freeze) and PIN_SEP or SEP
        parts[#parts + 1] = sep
        seps[#seps + 1] = { pos, pos + #sep }
        pos = pos + #sep
      end
      local cell = cells[c] or { text = '' }
      local t = text.pad(cell.text, widths[c], cell.right and 'right' or 'left')
      spans[c] = { pos, pos + #t }
      parts[#parts + 1] = t
      pos = pos + #t
    end
    return table.concat(parts), spans, seps
  end

  -- title
  local tabs = {}
  for i, v in ipairs(self.base.views) do
    tabs[#tabs + 1] = (i == self.vi and '[' .. v.name .. ']' or v.name)
  end
  local title = ('  ◆ %s   %s'):format(self.base.name or self.name, table.concat(tabs, '  '))
  local info = ('%d rows'):format(#rows)
  if res.total and res.total > #rows then info = info .. (' of %d'):format(res.total) end
  if res.matched and res.matched ~= res.total then info = info .. (' · %d files'):format(res.matched) end
  if #vis > 0 and (vis[#vis] < #cols or self.left > freeze + 1) then
    info = info .. (' · cols %d-%d/%d'):format(vis[freeze + 1] or vis[1], vis[#vis], #cols)
  end
  local gap = W - dw(title) - dw(info) - 2
  lines[1] = title .. (' '):rep(math.max(gap, 2)) .. info
  mark(0, 0, #lines[1], 'FeyDbTitle', 10)
  do
    local s = #('  ◆ ' .. (self.base.name or self.name) .. '   ')
    for i, t in ipairs(tabs) do
      if i == self.vi then mark(0, s, s + #t, 'FeyDbTab', 20) end
      s = s + #t + 2
    end
  end

  -- header
  local sort_of = {}
  for i, s in ipairs(view.sort or {}) do
    sort_of[s.prop] = { dir = s.dir, n = i }
  end
  local hcells = {}
  for _, c in ipairs(vis) do
    local col = cols[c]
    local t = text.type_glyph(self.model:prop_type(col.prop)) .. ' ' .. self:col_title(col)
    local so = sort_of[col.prop]
    if so then t = t .. (so.dir == 'desc' and '▼' or '▲') .. (#view.sort > 1 and so.n or '') end
    if view.group and view.group.prop == col.prop then t = t .. '◆' end
    hcells[c] = { text = text.truncate(t, widths[c]) }
  end
  local hline, hspans, hseps = build_line(hcells)
  lines[2] = hline
  mark(1, 0, #hline, 'FeyDbHeader', 10)
  if hspans[self.cur.col] then mark(1, hspans[self.cur.col][1], hspans[self.cur.col][2], 'FeyDbHeaderCur', 30) end

  -- separator
  local sep_parts = { '─' }
  for k, c in ipairs(vis) do
    if k > 1 then sep_parts[#sep_parts + 1] = (vis[k - 1] <= freeze and c > freeze) and '━╋━' or '─┼─' end
    sep_parts[#sep_parts + 1] = ('─'):rep(widths[c])
  end
  lines[3] = table.concat(sep_parts)
  mark(2, 0, #lines[3], 'FeyDbSep', 10)

  -- rows --------------------------------------------------------------------------------
  local entries = self.entries
  local blocks = {}

  local function block(e)
    if blocks[e] then return blocks[e] end
    local ent = entries[e]
    local b
    if ent.kind == 'group' then
      local label = ('▾ %s  (%d)'):format(text.cell_items(ent.key)[1] ~= '' and table.concat(text.cell_items(ent.key), ', ') or '(empty)', ent.count)
      b = { n = 1, lines = { ' ' .. label }, group = true }
    else
      local per_col, n = {}, 1
      local max_lines = view.row_height or 1
      for _, c in ipairs(vis) do
        local get = self.model:getter(cols[c].prop)
        local v = get(ent.row)
        local ls = text.cell_lines(v, widths[c], max_lines)
        per_col[c] = { lines = ls, right = type(v) == 'number', null = V.is_null(v) }
        n = math.max(n, #ls)
      end
      b = { n = n, per_col = per_col, spans = {}, seps = {}, lines = {} }
      for l = 1, n do
        local cells = {}
        for _, c in ipairs(vis) do
          cells[c] = { text = per_col[c].lines[l] or '', right = per_col[c].right }
        end
        b.lines[l], b.spans[l], b.seps[l] = build_line(cells)
      end
      if multi then
        b.lines[n + 1] = ' ' .. ('┄'):rep(math.max(W - 2, 1))
        b.divider = true
      end
      b.n = n + (multi and 1 or 0)
    end
    blocks[e] = b
    return b
  end

  local cur_entry = self.entry_of_row[self.cur.row]
  if #entries == 0 then
    self.top = 1
  else
    self.top = math.min(math.max(self.top, 1), #entries)
    if cur_entry then
      if cur_entry < self.top then
        self.top = cur_entry
        if self.top > 1 and entries[self.top - 1].kind == 'group' then self.top = self.top - 1 end
      else
        -- is the current row inside the window? If not, put it at the bottom
        local used, e = 0, self.top
        local inside = false
        while e <= #entries do
          local h = block(e).n
          if used + h > avail and e > self.top then break end
          used = used + h
          if e == cur_entry then
            inside = true
            break
          end
          e = e + 1
        end
        if not inside then
          local used2, t = 0, cur_entry
          while t >= 1 do
            local h = block(t).n
            if used2 + h > avail and t < cur_entry then break end
            used2 = used2 + h
            t = t - 1
          end
          self.top = t + 1
          if self.top > 1 and entries[self.top - 1].kind == 'group' and used2 + 1 <= avail then self.top = self.top - 1 end
        end
      end
    end
  end

  local first_cur_line, visible_rows = nil, 0
  local used = 0
  for e = self.top, #entries do
    local b = block(e)
    if used + b.n > avail and e > self.top then break end
    local ent = entries[e]
    used = used + b.n
    local base_line = #lines
    for l, line in ipairs(b.lines) do
      lines[#lines + 1] = line
    end
    if b.group then
      mark(base_line, 0, #b.lines[1], 'FeyDbGroup', 15)
    else
      visible_rows = visible_rows + 1
      local is_cur = ent.index == self.cur.row
      for l = 1, b.n - (b.divider and 1 or 0) do
        local ln = base_line + l - 1
        for _, s in ipairs(b.seps[l]) do
          mark(ln, s[1], s[2], 'FeyDbSep', 15)
        end
        if is_cur then
          mark(ln, 0, #b.lines[l], 'FeyDbRow', 5)
          local sp = b.spans[l][self.cur.col]
          if sp then mark(ln, sp[1], sp[2], 'FeyDbCell', 40) end
        end
      end
      if b.divider then mark(base_line + b.n - 1, 0, #b.lines[#b.lines], 'FeyDbSep', 5) end
      if is_cur then
        first_cur_line = base_line + 1
        self.cursor_byte = (b.spans[1][self.cur.col] or { 1 })[1]
      end
    end
  end
  self.visible_rows = math.max(visible_rows, 1)

  if #rows == 0 then
    lines[#lines + 1] = res.error and (' ⚠ ' .. res.error) or ' No rows match the filters'
    mark(#lines - 1, 0, #lines[#lines], 'FeyDbMsg', 10)
  end

  -- footer -------------------------------------------------------------------------------
  while #lines < H - 1 - (has_summary and 1 or 0) do
    lines[#lines + 1] = ''
  end
  if has_summary then
    local cells = {}
    for _, c in ipairs(vis) do
      local col = cols[c]
      if col.summary and col.summary ~= '' then
        local key = col.prop .. '\0' .. col.summary
        local v = self.summary_cache[key]
        if v == nil then
          v = self.model:summarize(col.summary, col.prop, rows)
          self.summary_cache[key] = v == nil and V.NULL or v
        end
        cells[c] = { text = text.truncate((SUMMARY_SHORT[col.summary] or col.summary) .. ' ' .. summary_text(v), widths[c]) }
      end
    end
    local sline = build_line(cells)
    lines[#lines + 1] = sline
    mark(#lines - 1, 0, #sline, 'FeyDbSummary', 10)
  end

  local status
  local col = cols[self.cur.col]
  if self.message then
    status = ' ' .. self.message.text
  else
    local ptype = col and self.model:prop_type(col.prop) or ''
    local scope = self.base.scope
    status = (' %s (%s) · row %d/%d%s · <Space> commands · g? help · q quit'):format(
      col and col.prop or '-', ptype, math.min(self.cur.row, #rows), #rows,
      scope and scope ~= 'current' and (' · scope ' .. scope_text(scope)) or ''
    )
  end
  lines[#lines + 1] = text.truncate(status, W)
  mark(#lines - 1, 0, #lines[#lines], self.message and self.message.warn and 'FeyDbMsg' or 'FeyDbStatus', 10)

  -- write ------------------------------------------------------------------------------------
  local buf = self.bufnr
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, m in ipairs(marks) do
    local line, s, e, group, prio = m[1], m[2], m[3], m[4], m[5]
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, line, s, { end_col = e, hl_group = group, priority = prio })
  end

  local cl = first_cur_line or 4
  pcall(vim.api.nvim_win_set_cursor, win, { math.min(cl, #lines), self.cursor_byte or 1 })
  vim.api.nvim_win_call(win, function() vim.fn.winrestview({ leftcol = 0 }) end)
end

-- Data refresh --------------------------------------------------------------------------------------

---Recompute rows, keeping the cursor on the same note when asked to
---@param keep? boolean
function View:refresh(keep)
  local path = keep and row_key(self.rows and self.rows[self.cur.row]) or nil
  self._res = nil
  self:result()
  if path then
    for i, r in ipairs(self.rows) do
      if row_key(r) == path then
        self.cur.row = i
        break
      end
    end
  end
  self:render()
end

function View:push_history()
  table.insert(self.history, vim.deepcopy(self.base))
  if #self.history > 60 then table.remove(self.history, 1) end
  self.future = {}
end

function View:save()
  if not self.dirty then return end
  self.dirty = false
  local ok, err = store.save(self.vault, self.name, self.base)
  if not ok then vim.notify('fey db: could not save: ' .. tostring(err), vim.log.levels.ERROR) end
end

function View:schedule_save()
  if self.save_timer then self.save_timer:stop() end
  self.save_timer = vim.defer_fn(function() self:save() end, 400)
end

---Change view settings: snapshots for undo, saves, redraws
---@param fn fun()
function View:mutate(fn)
  self:push_history()
  fn()
  self:sync_refs()
  self.model:invalidate()
  self.dirty = true
  self:schedule_save()
  self.message = nil
  self:refresh(true)
end

local function restore(self, snapshot)
  self.base = snapshot
  self:sync_refs()
  self.model:invalidate()
  self.dirty = true
  self:schedule_save()
  self:refresh(true)
end

function View:undo()
  local snap = table.remove(self.history)
  if not snap then return self:msg('nothing to undo') or self:render() end
  table.insert(self.future, vim.deepcopy(self.base))
  restore(self, snap)
end

function View:redo()
  local snap = table.remove(self.future)
  if not snap then return self:msg('nothing to redo') or self:render() end
  table.insert(self.history, vim.deepcopy(self.base))
  restore(self, snap)
end

-- Navigation ------------------------------------------------------------------------------------------

function View:move_row(delta)
  self.message = nil
  self.cur.row = math.min(math.max(self.cur.row + delta, 1), math.max(#self.rows, 1))
  self:render()
end

function View:move_col(delta)
  self.message = nil
  self.cur.col = math.min(math.max(self.cur.col + delta, 1), math.max(#self.view.columns, 1))
  self:render()
end

function View:goto_row(n)
  self.message = nil
  self.cur.row = math.min(math.max(n, 1), math.max(#self.rows, 1))
  self:render()
end

function View:goto_col(n)
  self.message = nil
  self.cur.col = math.min(math.max(n, 1), math.max(#self.view.columns, 1))
  self:render()
end

function View:page(dir) self:move_row(dir * math.max((self.visible_rows or 1) - 1, 1)) end

---@return table|nil col
function View:col() return self.view.columns[self.cur.col] end

---@return any row
function View:row() return self.rows[self.cur.row] end

-- Columns -------------------------------------------------------------------------------------------------

function View:add_column()
  local shown = {}
  for _, c in ipairs(self.view.columns) do
    shown[c.prop] = true
  end
  local items = {}
  for _, p in ipairs(self.model:properties()) do
    if not shown[p.id] then
      items[#items + 1] = { text = p.id, desc = p.count and ('note · %d files'):format(p.count) or p.kind }
    end
  end
  Fuzzy.open({
    prompt = 'Add column',
    items = items,
    allow_custom = true,
    on_confirm = function(_, name)
      if shown[name] then return self:goto_col(vim.fn.index(vim.tbl_map(function(c) return c.prop end, self.view.columns), name) + 1) end
      local at = self.cur.col
      self:mutate(function() table.insert(self.view.columns, at + 1, { prop = name }) end)
      self:goto_col(at + 1)
    end,
  })
end

function View:hide_column()
  if #self.view.columns <= 1 then return self:msg('a view needs at least one column', true) or self:render() end
  local at = self.cur.col
  self:mutate(function() table.remove(self.view.columns, at) end)
  self:goto_col(math.min(at, #self.view.columns))
end

function View:move_column(delta)
  local at, to = self.cur.col, self.cur.col + delta
  if to < 1 or to > #self.view.columns then return end
  self:mutate(function() self.view.columns[at], self.view.columns[to] = self.view.columns[to], self.view.columns[at] end)
  self:goto_col(to)
end

function View:resize(delta)
  local col = self:col()
  if not col then return end
  local current = col.width or self:auto_width(self.cur.col)
  self:mutate(function() col.width = math.max(current + delta, 4) end)
end

function View:auto_resize()
  local col = self:col()
  if col then self:mutate(function() col.width = nil end) end
end

function View:rename_column()
  local col = self:col()
  if not col then return end
  Fuzzy.open({
    prompt = 'Column title',
    default = col.display or '',
    on_confirm = function(_, t) self:mutate(function() col.display = t ~= '' and t or nil end) end,
  })
end

function View:set_summary()
  local col = self:col()
  if not col then return end
  local items = { { text = 'None', id = '' } }
  for _, s in ipairs(Model.SUMMARIES) do
    items[#items + 1] = { text = s.label, id = s.id }
  end
  Fuzzy.open({
    prompt = 'Summary of ' .. col.prop,
    items = items,
    on_confirm = function(item) self:mutate(function() col.summary = item.id ~= '' and item.id or nil end) end,
  })
end

function View:cycle_row_height()
  local cur = self.view.row_height or 1
  local nxt = ROW_HEIGHTS[1]
  for i, h in ipairs(ROW_HEIGHTS) do
    if h == cur then nxt = ROW_HEIGHTS[i % #ROW_HEIGHTS + 1] end
  end
  self:mutate(function() self.view.row_height = nxt end)
  self:msg(('row height %d'):format(nxt))
  self:render()
end

function View:set_freeze(n)
  self:mutate(function() self.view.freeze = n end)
end

-- Sort, group, filter --------------------------------------------------------------------------------------------------

---@param dir 'asc'|'desc'
---@param append? boolean
function View:sort(dir, append)
  local col = self:col()
  if not col then return end
  self:mutate(function()
    local list = self.view.sort
    if not append then
      self.view.sort = { { prop = col.prop, dir = dir } }
      return
    end
    for _, s in ipairs(list) do
      if s.prop == col.prop then
        s.dir = dir
        return
      end
    end
    list[#list + 1] = { prop = col.prop, dir = dir }
  end)
end

function View:clear_sort() self:mutate(function() self.view.sort = {} end) end

function View:toggle_group()
  local col = self:col()
  if not col then return end
  self:mutate(function()
    if self.view.group and self.view.group.prop == col.prop then
      self.view.group = nil
    else
      self.view.group = { prop = col.prop, dir = 'asc' }
    end
  end)
end

function View:filter_column()
  local col = self:col()
  if not col then return end
  FilterUI.edit_cond(self.model, { prop = col.prop }, function(cond)
    self:mutate(function()
      self.view.filters = self.view.filters or { kind = 'group', mode = 'and', items = {} }
      table.insert(self.view.filters.items, cond)
    end)
  end)
end

function View:filter_panel() FilterUI.panel(self) end

function View:clear_filters()
  self:mutate(function() self.view.filters = nil end)
end

function View:set_limit()
  Fuzzy.open({
    prompt = 'Limit rows (empty for all)',
    default = self.view.limit and tostring(self.view.limit) or '',
    on_confirm = function(_, t)
      local n = tonumber(t)
      self:mutate(function() self.view.limit = n and n > 0 and math.floor(n) or nil end)
    end,
  })
end

-- Scope ----------------------------------------------------------------------------------------------------------------------

---Which hollows the database shows: this one (`current`), this one and the hollows below it (`tree`), all
---of them (`court`), or a list of hollow references (`court:notes court:play:*`)
function View:set_scope()
  Fuzzy.open({
    prompt = 'Scope (or hollow references)',
    items = {
      { text = 'current', desc = 'this hollow' },
      { text = 'tree', desc = 'this hollow and the hollows below it' },
      { text = 'court', desc = 'every hollow' },
    },
    default = scope_text(self.base.scope),
    allow_custom = true,
    on_confirm = function(item, t)
      local value = item and item.text or t
      local words = vim.split(vim.trim(value), '[%s,]+', { trimempty = true })
      local spec
      if #words == 1 and (words[1] == 'current' or words[1] == 'tree' or words[1] == 'court') then
        spec = words[1] ~= 'current' and words[1] or nil
      elseif #words > 0 then
        spec = words
      end
      self:mutate(function() self.base.scope = spec end)
    end,
  })
end

-- Formulas ------------------------------------------------------------------------------------------------------------------

function View:add_formula()
  Fuzzy.open({
    prompt = 'Formula name',
    on_confirm = function(_, name)
      name = name:gsub('[^%w_]', '_')
      if name == '' then return end
      FilterUI.prompt_value(require('fey.db.filters').OP_BY_ID.expr, nil, function(expr)
        local at = self.cur.col
        self:mutate(function()
          local replaced = false
          for _, f in ipairs(self.base.formulas) do
            if f.name == name then
              f.expr, replaced = expr, true
            end
          end
          if not replaced then table.insert(self.base.formulas, { name = name, expr = expr }) end
          local prop = 'formula.' .. name
          for _, c in ipairs(self.view.columns) do
            if c.prop == prop then return end
          end
          table.insert(self.view.columns, at + 1, { prop = prop })
        end)
        self:goto_col(at + 1)
      end)
    end,
  })
end

function View:edit_formula()
  local col = self:col()
  local name = col and col.prop:match('^formula%.(.+)$')
  if not name then return self:msg('the cursor is not on a formula column', true) or self:render() end
  for _, f in ipairs(self.base.formulas) do
    if f.name == name then
      return FilterUI.prompt_value(require('fey.db.filters').OP_BY_ID.expr, f.expr, function(expr)
        self:mutate(function() f.expr = expr end)
      end)
    end
  end
end

-- Views -----------------------------------------------------------------------------------------------------------------------------

function View:switch_view(delta)
  self.vi = (self.vi - 1 + delta) % #self.base.views + 1
  self.view = self.base.views[self.vi]
  self.cur, self.top, self.left = { row = 1, col = 1 }, 1, 1
  self.message = nil
  self:refresh()
end

function View:new_view()
  Fuzzy.open({
    prompt = 'New view name',
    default = 'View ' .. (#self.base.views + 1),
    on_confirm = function(_, name)
      self:mutate(function()
        local copy = vim.deepcopy(self.view)
        copy.name = name
        table.insert(self.base.views, self.vi + 1, copy)
        self.vi = self.vi + 1
      end)
    end,
  })
end

function View:rename_view()
  Fuzzy.open({
    prompt = 'View name',
    default = self.view.name,
    on_confirm = function(_, name) self:mutate(function() self.view.name = name end) end,
  })
end

function View:delete_view()
  if #self.base.views <= 1 then return self:msg('a database needs at least one view', true) or self:render() end
  Fuzzy.open({
    prompt = 'Delete view ' .. self.view.name .. '?',
    items = { 'No', 'Yes' },
    on_confirm = function(item)
      if item.text ~= 'Yes' then return end
      self:mutate(function()
        table.remove(self.base.views, self.vi)
        self.vi = math.max(self.vi - 1, 1)
      end)
    end,
  })
end

function View:rename_database()
  Fuzzy.open({
    prompt = 'Database name',
    default = self.name,
    on_confirm = function(_, name)
      name = store.sanitize(name)
      self:save()
      local ok, err = store.rename(self.vault, self.name, name)
      if not ok then return vim.notify('fey db: ' .. tostring(err), vim.log.levels.WARN) end
      self.name = name
      self.base.name = name
      self.dirty = true
      self:save()
      self:render()
    end,
  })
end

-- Cells --------------------------------------------------------------------------------------------------------------------------------

---Apply a typed value to a note and update what is on screen
---@param row any
---@param prop string
---@param value any
function View:write_cell(row, prop, value)
  local path = row_path(row)
  if not path then return self:msg('this row is not a note', true) end
  local ok, err = source_edit.set(row_vault(self, row), path, prop, value)
  if not ok then
    self:msg('cannot edit: ' .. tostring(err), true)
    return self:render()
  end
  -- show the new value even when the index did not move (the buffer was modified)
  local page = rawget(row, '__parent') or row
  ops.get(page, prop)
  local data = rawget(page, '__data')
  if data then
    if value == nil then data[prop] = nil else data[prop] = V.from_json(value, true) end
  end
  self.model.result_cache, self.model.types = nil, nil
  self.message = nil
  self:msg(value == nil and (prop .. ' cleared') or (prop .. ' set'))
  self:refresh(true)
end

function View:edit_cell()
  local row, col = self:row(), self:col()
  if not row or not col then return end
  local prop = col.prop
  if prop:match('^file%.') then return self:msg('file properties are read-only', true) or self:render() end
  if prop:match('^formula%.') then return self:msg('edit the formula with the command palette', true) or self:render() end

  local v = self.model:getter(prop)(row)
  local ptype = self.model:prop_type(prop)
  if type(v) == 'boolean' then return self:write_cell(row, prop, not v) end
  Fuzzy.open({
    prompt = 'Edit ' .. prop,
    default = text.edit_text(v),
    on_confirm = function(_, t)
      local value = source_edit.parse_input(t, (ptype ~= 'mixed' and ptype ~= 'date' and ptype ~= 'link') and ptype or nil)
      self:write_cell(row, prop, value)
    end,
  })
end

function View:clear_cell()
  local row, col = self:row(), self:col()
  if not row or not col or col.prop:match('^file%.') or col.prop:match('^formula%.') then
    return self:msg('only note properties can be cleared', true) or self:render()
  end
  self:write_cell(row, col.prop, nil)
end

function View:yank_cell()
  local row, col = self:row(), self:col()
  if not row or not col then return end
  local t = text.edit_text(self.model:getter(col.prop)(row))
  vim.fn.setreg('"', t)
  pcall(vim.fn.setreg, '+', t)
  self:msg('yanked: ' .. text.truncate(t, 40))
  self:render()
end

---@param how 'split'|'tab'
function View:open_note(how)
  local row = self:row()
  local path = row_path(row)
  if not path then return end
  vim.cmd((how == 'tab' and 'tabedit ' or 'belowright split ') .. vim.fn.fnameescape(row_vault(self, row):abs(path)))
end

-- Search ------------------------------------------------------------------------------------------------------------------------------

---@param dir integer
function View:search_next(dir)
  if not self.search then return end
  local col = self:col()
  local ok, re = pcall(vim.regex, self.search)
  if not ok or not col then return self:msg('invalid pattern', true) or self:render() end
  local get = self.model:getter(col.prop)
  local n = #self.rows
  for step = 1, n do
    local i = (self.cur.row - 1 + dir * step) % n + 1
    local cell = table.concat(text.cell_items(get(self.rows[i])), ' ')
    if re:match_str(cell) then
      self.cur.row = i
      self.message = nil
      return self:render()
    end
  end
  self:msg('no match for ' .. self.search, true)
  self:render()
end

function View:search()
  Fuzzy.open({
    prompt = 'Search in column (regex)',
    default = self.search or '',
    on_confirm = function(_, t)
      self.search = t
      self:search_next(1)
    end,
  })
end

function View:refresh_vault()
  self:msg('rescanning the vault…')
  self:render()
  self.vault:scan({}, function() end)
end

-- Palette and help ------------------------------------------------------------------------------------------------------------------------

---@type { name: string, key?: string, fn: fun(self: FeyDbView) }[]
local ACTIONS = {
  { name = 'Add column', key = 'a', fn = View.add_column },
  { name = 'Hide column', key = '-', fn = View.hide_column },
  { name = 'Move column left', key = 'H', fn = function(s) s:move_column(-1) end },
  { name = 'Move column right', key = 'L', fn = function(s) s:move_column(1) end },
  { name = 'Widen column', key = '>', fn = function(s) s:resize(4) end },
  { name = 'Narrow column', key = '<', fn = function(s) s:resize(-4) end },
  { name = 'Auto width', key = '_', fn = View.auto_resize },
  { name = 'Rename column title', key = '^', fn = View.rename_column },
  { name = 'Column summary', key = 's', fn = View.set_summary },
  { name = 'Sort ascending', key = '[', fn = function(s) s:sort('asc') end },
  { name = 'Sort descending', key = ']', fn = function(s) s:sort('desc') end },
  { name = 'Add sort key ascending', key = 'g[', fn = function(s) s:sort('asc', true) end },
  { name = 'Add sort key descending', key = 'g]', fn = function(s) s:sort('desc', true) end },
  { name = 'Clear sort', key = 'g\\', fn = View.clear_sort },
  { name = 'Group by column', key = '!', fn = View.toggle_group },
  { name = 'Filter on column', key = 'f', fn = View.filter_column },
  { name = 'Filter panel', key = 'F', fn = View.filter_panel },
  { name = 'Clear filters', key = 'gF', fn = View.clear_filters },
  { name = 'Add formula column', key = '=', fn = View.add_formula },
  { name = 'Edit formula of column', fn = View.edit_formula },
  { name = 'Row height', key = 'R', fn = View.cycle_row_height },
  { name = 'Limit rows', fn = View.set_limit },
  { name = 'Pin columns up to cursor', fn = function(s) s:set_freeze(s.cur.col) end },
  { name = 'Unpin columns', fn = function(s) s:set_freeze(0) end },
  { name = 'Edit cell', key = '<CR>', fn = View.edit_cell },
  { name = 'Clear cell', key = 'gx', fn = View.clear_cell },
  { name = 'Yank cell', key = 'y', fn = View.yank_cell },
  { name = 'Open note in split', key = 'o', fn = function(s) s:open_note('split') end },
  { name = 'Open note in tab', key = 'O', fn = function(s) s:open_note('tab') end },
  { name = 'Search column', key = '/', fn = View.search },
  { name = 'Next view', key = '<Tab>', fn = function(s) s:switch_view(1) end },
  { name = 'Previous view', key = '<S-Tab>', fn = function(s) s:switch_view(-1) end },
  { name = 'New view', key = 'gn', fn = View.new_view },
  { name = 'Rename view', fn = View.rename_view },
  { name = 'Delete view', fn = View.delete_view },
  { name = 'Rename database', fn = View.rename_database },
  { name = 'Scope: which hollows to show', key = 'gs', fn = View.set_scope },
  { name = 'Rescan vault', key = 'r', fn = View.refresh_vault },
  { name = 'Undo', key = 'u', fn = View.undo },
  { name = 'Redo', key = '<C-r>', fn = View.redo },
}

function View:palette()
  local items = {}
  for i, a in ipairs(ACTIONS) do
    items[i] = { text = a.name, desc = a.key, idx = i }
  end
  Fuzzy.open({
    prompt = 'Command',
    items = items,
    on_confirm = function(item) ACTIONS[item.idx].fn(self) end,
  })
end

function View:help()
  local lines = {
    ' Database view ',
    '',
    ' h j k l / arrows   move between cells        gg G {n}G   first / last / row n',
    ' 0 $                first / last column       C-d C-u     page down / up',
    ' <Space>            command palette           g?          this help',
    ' q                  close',
    '',
  }
  for _, a in ipairs(ACTIONS) do
    lines[#lines + 1] = (' %-8s %s'):format(a.key or '', a.name)
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local width = 64
  local height = math.min(#lines, vim.o.lines - 4)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor', width = width, height = height,
    row = math.floor((vim.o.lines - height) / 2), col = math.floor((vim.o.columns - width) / 2),
    style = 'minimal', border = 'rounded', title = ' Help ', zindex = 160,
  })
  vim.keymap.set('n', 'q', function() vim.api.nvim_win_close(win, true) end, { buffer = buf, nowait = true })
  vim.keymap.set('n', '<Esc>', function() vim.api.nvim_win_close(win, true) end, { buffer = buf, nowait = true })
end

function View:close()
  self:save()
  local buf = self.bufnr
  if #vim.api.nvim_tabpage_list_wins(0) > 1 or #vim.api.nvim_list_tabpages() > 1 then
    local win = vim.fn.bufwinid(buf)
    if win ~= -1 then pcall(vim.api.nvim_win_close, win, true) end
  end
  if vim.api.nvim_buf_is_valid(buf) then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
end

-- Opening ---------------------------------------------------------------------------------------------------------------------------------

---@param self FeyDbView
local function install_keymaps(self)
  local buf = self.bufnr
  local function map(lhs, fn, desc)
    vim.keymap.set('n', lhs, fn, { buffer = buf, nowait = true, silent = true, desc = 'fey db: ' .. desc })
  end
  for _, a in ipairs(ACTIONS) do
    if a.key then map(a.key, function() a.fn(self) end, a.name) end
  end
  map('e', function() self:edit_cell() end, 'Edit cell')
  map('j', function() self:move_row(vim.v.count1) end, 'down')
  map('k', function() self:move_row(-vim.v.count1) end, 'up')
  map('<Down>', function() self:move_row(vim.v.count1) end, 'down')
  map('<Up>', function() self:move_row(-vim.v.count1) end, 'up')
  map('h', function() self:move_col(-vim.v.count1) end, 'left')
  map('l', function() self:move_col(vim.v.count1) end, 'right')
  map('<Left>', function() self:move_col(-vim.v.count1) end, 'left')
  map('<Right>', function() self:move_col(vim.v.count1) end, 'right')
  map('gg', function() self:goto_row(1) end, 'first row')
  map('G', function() self:goto_row(vim.v.count > 0 and vim.v.count or #self.rows) end, 'last row')
  map('0', function() self:goto_col(1) end, 'first column')
  map('^^', function() self:goto_col(1) end, 'first column')
  map('$', function() self:goto_col(#self.view.columns) end, 'last column')
  map('<C-d>', function() self:page(1) end, 'page down')
  map('<C-u>', function() self:page(-1) end, 'page up')
  map('<C-f>', function() self:page(1) end, 'page down')
  map('<C-b>', function() self:page(-1) end, 'page up')
  map('<PageDown>', function() self:page(1) end, 'page down')
  map('<PageUp>', function() self:page(-1) end, 'page up')
  map('n', function() self:search_next(1) end, 'next match')
  map('N', function() self:search_next(-1) end, 'previous match')
  map('<Space>', function() self:palette() end, 'command palette')
  map('g?', function() self:help() end, 'help')
  map('q', function() self:close() end, 'close')
  map('<Esc>', function() self.message = nil self:render() end, 'clear message')
end

local autocmds_ready = false

local function setup_autocmds()
  if autocmds_ready then return end
  autocmds_ready = true
  local group = vim.api.nvim_create_augroup('fey_db_view', { clear = true })
  vim.api.nvim_create_autocmd({ 'WinResized', 'VimResized' }, {
    group = group,
    callback = function()
      for _, inst in pairs(instances) do
        if vim.api.nvim_buf_is_valid(inst.bufnr) then inst:render() end
      end
    end,
  })
  local pending
  vim.api.nvim_create_autocmd('User', {
    group = group,
    pattern = { 'FeyVaultIndexed', 'FeyVaultFileIndexed' },
    callback = function()
      if pending then return end
      pending = vim.defer_fn(function()
        pending = nil
        for _, inst in pairs(instances) do
          if vim.api.nvim_buf_is_valid(inst.bufnr) then
            inst.message = nil
            inst:refresh(true)
          end
        end
      end, 120)
    end,
  })
  vim.api.nvim_create_autocmd('ColorScheme', { group = group, callback = define_highlights })
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = group,
    callback = function()
      for _, inst in pairs(instances) do
        inst:save()
      end
    end,
  })
end

---@alias FeyDbOpenMode 'split'|'vsplit'|'tab'|'current'

---Open a database in a new window, split or tab
---@param vault FeyVault
---@param name string
---@param mode? FeyDbOpenMode
---@return FeyDbView|nil
function M.open(vault, name, mode)
  define_highlights()
  setup_autocmds()
  local base, err = store.load(vault, name)
  if not base then
    vim.notify('fey db: ' .. tostring(err), vim.log.levels.ERROR)
    return nil
  end

  mode = mode or 'vsplit'
  if mode == 'split' then vim.cmd('botright split')
  elseif mode == 'vsplit' then vim.cmd('botright vsplit')
  elseif mode == 'tab' then vim.cmd('tabnew') end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, buf)
  pcall(vim.api.nvim_buf_set_name, buf, ('feydb://%s#%d'):format(name, buf))
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'feydb'
  vim.bo[buf].modifiable = false
  local win = vim.api.nvim_get_current_win()
  for opt, val in pairs({
    wrap = false, number = false, relativenumber = false, signcolumn = 'no', cursorline = false, foldcolumn = '0',
    list = false, spell = false, colorcolumn = '', winfixbuf = true,
  }) do
    pcall(function() vim.wo[win][opt] = val end)
  end

  local self = setmetatable({
    vault = vault, name = name, base = base, vi = 1, bufnr = buf,
    cur = { row = 1, col = 1 }, top = 1, left = 1, history = {}, future = {}, auto_w = {}, summary_cache = {},
    rows = {}, entries = {}, entry_of_row = {},
  }, View)
  self.model = Model.new(vault, base)
  self:sync_refs()
  instances[buf] = self

  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = buf,
    once = true,
    callback = function()
      self:save()
      instances[buf] = nil
    end,
  })
  install_keymaps(self)
  self:refresh()
  return self
end

M.View = View
return M
