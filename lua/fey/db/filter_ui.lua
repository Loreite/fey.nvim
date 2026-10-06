-- Interactive pieces for editing filters: the property -> operator -> value flow
-- and the filter panel (a small tree editor in a floating window).
local Fuzzy = require('fey.ui.fuzzy')
local filters = require('fey.db.filters')

local M = {}

-- Which operator groups come first for a property type
local GROUP_ORDER = {
  number = { 'compare', 'presence', 'length', 'custom' },
  date = { 'date', 'compare', 'presence', 'custom' },
  boolean = { 'boolean', 'presence', 'compare', 'custom' },
  list = { 'text', 'length', 'presence', 'compare', 'file', 'custom' },
  string = { 'text', 'compare', 'presence', 'length', 'file', 'custom' },
}

---@param model FeyDbModel
---@param cb fun(prop: string)
---@param prompt? string
function M.pick_property(model, cb, prompt)
  local items = {}
  for _, p in ipairs(model:properties()) do
    local desc = p.kind
    if p.count then desc = ('note · %d files'):format(p.count) end
    items[#items + 1] = { text = p.id, desc = desc }
  end
  Fuzzy.open({
    prompt = prompt or 'Property',
    items = items,
    allow_custom = true,
    on_confirm = function(_, text) cb(text) end,
  })
end

---@param ptype? string
---@param cb fun(op: FeyDbOp)
function M.pick_operator(ptype, cb)
  local order = GROUP_ORDER[ptype or 'string'] or GROUP_ORDER.string
  local rank = {}
  for i, g in ipairs(order) do
    rank[g] = i
  end
  local ops_sorted = vim.list_slice(filters.OPS)
  table.sort(ops_sorted, function(a, b)
    local ra, rb = rank[a.group] or 99, rank[b.group] or 99
    if ra ~= rb then return ra < rb end
    return false
  end)
  local items = {}
  for i, op in ipairs(ops_sorted) do
    items[i] = { text = op.label, desc = op.group, id = op.id }
  end
  Fuzzy.open({
    prompt = 'Operator',
    items = items,
    on_confirm = function(item)
      if item then cb(filters.OP_BY_ID[item.id]) end
    end,
  })
end

---@param op FeyDbOp
---@param default? string
---@param cb fun(value: string|nil)
function M.prompt_value(op, default, cb)
  if op.arity == 0 then return cb(nil) end
  Fuzzy.open({
    prompt = op.id == 'expr' and 'Expression' or ('Value (' .. op.label .. ')'),
    default = default,
    on_confirm = function(_, text)
      if op.id == 'expr' then
        local err = filters.validate(text)
        if err then
          vim.notify('fey db: ' .. err, vim.log.levels.WARN)
          return M.prompt_value(op, text, cb)
        end
      end
      cb(text)
    end,
  })
end

---Build or edit one condition through the prompts
---@param model FeyDbModel
---@param opts { existing?: table, prop?: string, expr?: boolean }
---@param cb fun(cond: table)
function M.edit_cond(model, opts, cb)
  opts = opts or {}
  local existing = opts.existing

  local function finish_expr()
    M.prompt_value(filters.OP_BY_ID.expr, existing and existing.expr or nil, function(text)
      cb({ kind = 'expr', expr = text })
    end)
  end
  if opts.expr or (existing and existing.kind == 'expr') then return finish_expr() end

  local function with_prop(prop)
    local ptype = model:prop_type(prop)
    M.pick_operator(ptype, function(op)
      if op.id == 'expr' then return finish_expr() end
      local default = existing and existing.prop == prop and existing.op == op.id and existing.value or nil
      M.prompt_value(op, default, function(value)
        cb({ kind = 'cond', prop = prop, op = op.id, value = value })
      end)
    end)
  end

  if opts.prop then
    with_prop(opts.prop)
  elseif existing and existing.prop then
    with_prop(existing.prop)
  else
    M.pick_property(model, with_prop)
  end
end

-- Panel -----------------------------------------------------------------------------------------

local MODES = { 'and', 'or', 'not' }
local MODE_LABEL = { ['and'] = 'all of', ['or'] = 'any of', ['not'] = 'none of' }

---@param view FeyDbView
function M.panel(view)
  local scope = 'view'
  local prev_win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = 'feydb_filters'

  local width = math.min(80, vim.o.columns - 6)
  local height = math.min(18, math.max(vim.o.lines - 8, 6))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor', width = width, height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1, col = math.floor((vim.o.columns - width) / 2),
    style = 'minimal', border = 'rounded', zindex = 150,
    title = ' Filters ', title_pos = 'left',
    footer = ' a add · A expression · g group · m mode · e edit · d delete · s scope · q close ', footer_pos = 'left',
  })
  vim.wo[win].cursorline = true
  vim.wo[win].winhighlight = 'NormalFloat:Normal,FloatBorder:FloatBorder'

  ---@type { node: table, parent: table|nil, idx: integer|nil }[]
  local entries = {}

  local function holder() return scope == 'view' and view.view or view.base end

  ---@return table root group (created on demand)
  local function root()
    local h = holder()
    if not h.filters then h.filters = filters.group('and') end
    return h.filters
  end

  local function render()
    entries = {}
    local lines = {}
    local function walk(node, parent, idx, depth)
      entries[#entries + 1] = { node = node, parent = parent, idx = idx }
      local pad = ('  '):rep(depth)
      if node.kind == 'group' then
        lines[#lines + 1] = ('%s▾ %s (%d)'):format(pad, MODE_LABEL[node.mode or 'and'] or 'all of', #node.items)
        for i, item in ipairs(node.items) do
          walk(item, node, i, depth + 1)
        end
      else
        lines[#lines + 1] = pad .. '  ' .. filters.describe(node)
      end
    end
    walk(root(), nil, nil, 0)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_win_set_config(win, {
      title = scope == 'view' and (' Filters · view ' .. (view.view.name or '') .. ' ') or ' Filters · all views of this database ',
      title_pos = 'left',
    })
  end

  local function current()
    local line = vim.api.nvim_win_get_cursor(win)[1]
    return entries[line] or entries[1]
  end

  ---Group that new entries go into
  local function target_group()
    local e = current()
    if e.node.kind == 'group' then return e.node end
    return e.parent or root()
  end

  local function changed(fn)
    view:mutate(fn)
    if vim.api.nvim_win_is_valid(win) then
      local pos = vim.api.nvim_win_get_cursor(win)
      render()
      pcall(vim.api.nvim_win_set_cursor, win, { math.min(pos[1], #entries), 0 })
    end
  end

  local function close()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    if vim.api.nvim_win_is_valid(prev_win) then vim.api.nvim_set_current_win(prev_win) end
  end

  local function map(lhs, fn) vim.keymap.set('n', lhs, fn, { buffer = buf, nowait = true, silent = true }) end

  map('q', close)
  map('<Esc>', close)
  map('s', function()
    scope = scope == 'view' and 'base' or 'view'
    render()
  end)
  map('a', function()
    local group = target_group()
    M.edit_cond(view.model, {}, function(cond)
      changed(function() table.insert(group.items, cond) end)
    end)
  end)
  map('A', function()
    local group = target_group()
    M.edit_cond(view.model, { expr = true }, function(cond)
      changed(function() table.insert(group.items, cond) end)
    end)
  end)
  map('g', function()
    local group = target_group()
    changed(function() table.insert(group.items, filters.group('or')) end)
  end)
  map('m', function()
    local e = current()
    local g = e.node.kind == 'group' and e.node or e.parent
    if not g then return end
    changed(function()
      for i, m in ipairs(MODES) do
        if m == (g.mode or 'and') then
          g.mode = MODES[i % #MODES + 1]
          break
        end
      end
    end)
  end)
  map('d', function()
    local e = current()
    if not e.parent then
      return changed(function() holder().filters = nil end)
    end
    changed(function() table.remove(e.parent.items, e.idx) end)
  end)
  local function edit()
    local e = current()
    if e.node.kind == 'group' then
      return changed(function()
        for i, m in ipairs(MODES) do
          if m == (e.node.mode or 'and') then
            e.node.mode = MODES[i % #MODES + 1]
            break
          end
        end
      end)
    end
    M.edit_cond(view.model, { existing = e.node }, function(cond)
      changed(function() e.parent.items[e.idx] = cond end)
    end)
  end
  map('e', edit)
  map('<CR>', edit)

  render()
end

return M
