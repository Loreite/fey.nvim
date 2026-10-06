-- A one line input with an optional fuzzy matched dropdown (VisiData style).
--
--   require('fey.ui.fuzzy').open({
--     prompt = 'Add column',
--     items = { { text = 'file.name', desc = 'file' }, ... },   -- omit for plain text input
--     default = '',
--     allow_custom = false,       -- Enter on text that matches nothing returns the text
--     on_confirm = function(item, text) end,
--   })
--
-- Keys: <C-n>/<Down>/<Tab> and <C-p>/<Up>/<S-Tab> move, <CR> confirms the selected
-- entry, <C-y> confirms the typed text as is (when allowed), <Esc>/<C-c> cancels.
local M = {}

local ns = vim.api.nvim_create_namespace('fey_fuzzy')
local MAX_ITEMS = 10

---@class FeyFuzzyItem
---@field text string what is matched and returned
---@field desc? string dimmed text after the label

---@class FeyFuzzyOpts
---@field prompt? string
---@field items? (FeyFuzzyItem|string)[]
---@field default? string
---@field allow_custom? boolean
---@field on_confirm fun(item: FeyFuzzyItem|nil, text: string)
---@field on_cancel? fun()

---@param opts FeyFuzzyOpts
function M.open(opts)
  local prev_win = vim.api.nvim_get_current_win()
  local items = {}
  for i, it in ipairs(opts.items or {}) do
    items[i] = type(it) == 'string' and { text = it } or it
  end
  local pick_mode = opts.items ~= nil

  local width = math.min(64, math.max(vim.o.columns - 6, 20))
  local row = math.max(math.floor(vim.o.lines * 0.2), 1)
  local col = math.floor((vim.o.columns - width) / 2)

  local ibuf = vim.api.nvim_create_buf(false, true)
  vim.bo[ibuf].bufhidden = 'wipe'
  vim.bo[ibuf].filetype = 'feydb_input'
  local iwin = vim.api.nvim_open_win(ibuf, true, {
    relative = 'editor', row = row, col = col, width = width, height = 1,
    style = 'minimal', border = 'rounded', title = ' ' .. (opts.prompt or 'Input') .. ' ', title_pos = 'left',
    zindex = 200,
  })
  vim.wo[iwin].winhighlight = 'NormalFloat:Normal,FloatBorder:FloatBorder,FloatTitle:Title'
  vim.api.nvim_buf_set_lines(ibuf, 0, -1, false, { opts.default or '' })

  local lbuf, lwin
  local matches, positions = {}, {}
  local sel = 1
  local closed = false

  local function close()
    if closed then return end
    closed = true
    vim.cmd('stopinsert')
    if lwin and vim.api.nvim_win_is_valid(lwin) then vim.api.nvim_win_close(lwin, true) end
    if vim.api.nvim_win_is_valid(iwin) then vim.api.nvim_win_close(iwin, true) end
    if vim.api.nvim_win_is_valid(prev_win) then vim.api.nvim_set_current_win(prev_win) end
  end

  local function query() return vim.api.nvim_buf_get_lines(ibuf, 0, 1, false)[1] or '' end

  local function render_list()
    if not pick_mode then return end
    local q = query()
    if q == '' then
      matches, positions = items, {}
    else
      local res = vim.fn.matchfuzzypos(items, q, { key = 'text' })
      matches, positions = res[1], res[2]
    end
    sel = math.min(math.max(sel, 1), math.max(#matches, 1))

    local shown = math.min(#matches, MAX_ITEMS)
    if shown == 0 then
      if lwin and vim.api.nvim_win_is_valid(lwin) then vim.api.nvim_win_close(lwin, true) end
      lwin = nil
      return
    end
    if not lbuf or not vim.api.nvim_buf_is_valid(lbuf) then
      lbuf = vim.api.nvim_create_buf(false, true)
      vim.bo[lbuf].bufhidden = 'wipe'
    end
    local first = math.max(math.min(sel - math.floor(MAX_ITEMS / 2), #matches - MAX_ITEMS + 1), 1)
    local lines = {}
    for i = first, first + shown - 1 do
      local m = matches[i]
      lines[#lines + 1] = ' ' .. m.text .. (m.desc and ('  ' .. m.desc) or '')
    end
    vim.api.nvim_buf_set_lines(lbuf, 0, -1, false, lines)
    vim.api.nvim_buf_clear_namespace(lbuf, ns, 0, -1)
    for i = first, first + shown - 1 do
      local line = i - first
      local m = matches[i]
      if i == sel then
        vim.api.nvim_buf_set_extmark(lbuf, ns, line, 0, { line_hl_group = 'PmenuSel', priority = 10 })
      end
      if m.desc then
        vim.api.nvim_buf_set_extmark(lbuf, ns, line, 1 + #m.text, { end_col = #lines[line + 1], hl_group = 'Comment', priority = 20 })
      end
      for _, p in ipairs(positions[i] or {}) do
        vim.api.nvim_buf_set_extmark(lbuf, ns, line, 1 + p, { end_col = 2 + p, hl_group = 'Special', priority = 30 })
      end
    end
    local cfg = {
      relative = 'editor', row = row + 3, col = col, width = width, height = shown,
      style = 'minimal', border = 'rounded', zindex = 201,
    }
    if lwin and vim.api.nvim_win_is_valid(lwin) then
      vim.api.nvim_win_set_config(lwin, cfg)
    else
      lwin = vim.api.nvim_open_win(lbuf, false, cfg)
      vim.wo[lwin].winhighlight = 'NormalFloat:Pmenu,FloatBorder:FloatBorder'
    end
  end

  local function confirm(raw)
    local text = query()
    local item = (not raw and pick_mode) and matches[sel] or nil
    if pick_mode and not item then
      if not (opts.allow_custom and text ~= '') then return end
    end
    close()
    vim.schedule(function() opts.on_confirm(item, item and item.text or text) end)
  end

  local function cancel()
    close()
    if opts.on_cancel then vim.schedule(opts.on_cancel) end
  end

  local function move(delta)
    if #matches == 0 then return end
    sel = ((sel - 1 + delta) % #matches) + 1
    render_list()
  end

  local function map(modes, lhs, fn)
    vim.keymap.set(modes, lhs, fn, { buffer = ibuf, nowait = true, silent = true })
  end
  map('i', '<CR>', function() confirm(false) end)
  map('i', '<C-y>', function() if opts.allow_custom or not pick_mode then confirm(true) end end)
  map({ 'i', 'n' }, '<Esc>', cancel)
  map({ 'i', 'n' }, '<C-c>', cancel)
  map('n', '<CR>', function() confirm(false) end)
  map('n', 'q', cancel)
  map('i', '<C-n>', function() move(1) end)
  map('i', '<Down>', function() move(1) end)
  map('i', '<Tab>', function() move(1) end)
  map('i', '<C-p>', function() move(-1) end)
  map('i', '<Up>', function() move(-1) end)
  map('i', '<S-Tab>', function() move(-1) end)

  vim.api.nvim_create_autocmd({ 'TextChangedI', 'TextChanged' }, {
    buffer = ibuf,
    callback = function()
      sel = 1
      render_list()
    end,
  })
  vim.api.nvim_create_autocmd('WinLeave', {
    buffer = ibuf,
    once = true,
    callback = function() vim.schedule(function() if not closed then cancel() end end) end,
  })

  render_list()
  vim.cmd('startinsert!')
end

return M
