local config = require('fey.config')
local colors = require('fey.colors')
local utils = require('fey.utils')
local M = {}

function M.define_highlights()
  M.define_palette()
  M.link_highlights()
  M.define_emphasis_highlights()
  M.define_agenda_colors()
  M.define_fey_todo_keyword_colors()
  M.define_todo_keyword_faces()
  M.setup_autocmds()
end

-- ---------------------------------------------------------------------------
-- Palette
--
-- `@fey.color.<name>` groups that everything else builds on. Each entry lists
-- where the colour comes from, in order:
--   1. the chocolatier group (linked directly when that colorscheme is active)
--   2. common groups whose foreground carries that colour in most schemes
--   3. `blend`: Normal fg mixed toward Normal bg by that fraction
-- Only the foreground is copied from fallback groups, so a scheme's bold or
-- italic on e.g. `String` does not leak into emphasis.
-- ---------------------------------------------------------------------------
local PALETTE = {
  red = { 'ChocolatierRed', 'DiagnosticError', 'Statement' },
  orange = { 'ChocolatierOrange', 'Special', 'Constant' },
  green = { 'ChocolatierGreen', 'DiagnosticOk', 'String' },
  yellow = { 'ChocolatierYellow', 'DiagnosticWarn', 'Type' },
  fuscia = { 'ChocolatierFuscia', 'Function', 'Title' },
  blue = { 'ChocolatierBlue', 'DiagnosticInfo', 'Identifier' },
  purple = { 'ChocolatierPurple', 'Constant', 'Number' },
  teal = { 'ChocolatierTeal', 'DiagnosticHint', 'PreProc' },
  gray = { 'ChocolatierAltG', 'Comment', blend = 0.45 },
  fg2 = { 'ChocolatierFg2', blend = 0.12 },
  fg3 = { 'ChocolatierFg3', blend = 0.25 },
  bg2 = { 'ChocolatierBg2', 'NonText', blend = 0.70 },
}

---@param name string
---@return table?
local function get_hl(name)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  if ok and hl and not vim.tbl_isempty(hl) then return hl end
end

-- Groups this module computes from the colorscheme, with the value it last
-- set. A group that still holds that value is ours and gets refreshed when
-- the colours change; anything else was set by the user or a colorscheme and
-- is left alone. (`default = true` cannot do this: it would also keep a stale
-- value computed before the colorscheme loaded.)
local owned = {}

local function set_owned(name, def)
  def.default = nil
  local current = vim.api.nvim_get_hl(0, { name = name })
  if not vim.tbl_isempty(current) and not vim.deep_equal(current, owned[name]) then return end
  vim.api.nvim_set_hl(0, name, def)
  owned[name] = vim.api.nvim_get_hl(0, { name = name })
end

---@param a integer  rgb
---@param b integer  rgb
---@param t number   0 = a, 1 = b
local function blend(a, b, t)
  local out = 0
  for _, shift in ipairs({ 65536, 256, 1 }) do
    local ca = math.floor(a / shift) % 256
    local cb = math.floor(b / shift) % 256
    out = out + math.floor(ca + (cb - ca) * t + 0.5) * shift
  end
  return out
end

-- Background to put behind "highlight" (double) emphasis text, or nil for a
-- transparent Normal.
local function normal_bg()
  local normal = get_hl('Normal')
  return normal and normal.bg, normal and normal.ctermbg
end

-- A soft background band for doubled code / verbatim / quote.
local function soft_bg()
  local choc = get_hl('ChocolatierBg1')
  if choc and choc.fg then return choc.fg, choc.ctermfg end
  local normal = get_hl('Normal')
  if normal and normal.bg and normal.fg then return blend(normal.bg, normal.fg, 0.10), nil end
  local cl = get_hl('CursorLine')
  return cl and cl.bg, cl and cl.ctermbg
end

---@param spec table
---@return table definition for nvim_set_hl
local function resolve_color(spec)
  local primary = spec[1] and get_hl(spec[1])
  if primary and primary.fg and spec[1]:match('^Chocolatier') then return { link = spec[1] } end
  for _, group in ipairs(spec) do
    local hl = get_hl(group)
    if hl and (hl.fg or hl.ctermfg) then return { fg = hl.fg, ctermfg = hl.ctermfg } end
  end
  local normal = get_hl('Normal')
  if normal and normal.fg then
    if spec.blend and normal.bg then return { fg = blend(normal.fg, normal.bg, spec.blend), ctermfg = normal.ctermfg } end
    return { fg = normal.fg, ctermfg = normal.ctermfg }
  end
  return {}
end

function M.define_palette()
  for name, spec in pairs(PALETTE) do
    set_owned('@fey.color.' .. name, resolve_color(spec))
  end
end

function M.link_highlights()
  local links = {
    -- Headings (same colour order as chocolatier)
    ['@fey.heading.level1'] = '@fey.color.purple',
    ['@fey.heading.level2'] = '@fey.color.blue',
    ['@fey.heading.level3'] = '@fey.color.teal',
    ['@fey.heading.level4'] = '@fey.color.green',
    ['@fey.heading.level5'] = '@fey.color.yellow',
    ['@fey.heading.level6'] = '@fey.color.orange',
    ['@fey.heading.level7'] = '@fey.color.red',
    ['@fey.heading.level8'] = '@fey.color.fuscia',

    ['@fey.priority.highest'] = '@comment.error',

    -- Heading tags
    ['@fey.tag'] = '@tag.attribute',

    -- Heading plan
    ['@fey.plan'] = 'Constant',

    -- Timestamps
    ['@fey.timestamp.active'] = '@keyword',
    ['@fey.timestamp.inactive'] = '@comment',

    -- Lists/Checkboxes
    ['@fey.bullet'] = '@markup.list',
    ['@fey.checkbox'] = '@markup.list.unchecked',
    ['@fey.checkbox.halfchecked'] = '@markup.list.unchecked',
    ['@fey.checkbox.checked'] = '@markup.list.checked',

    -- Drawers
    ['@fey.properties'] = '@property',
    ['@fey.properties.name'] = '@property',
    ['@fey.drawer'] = '@property',

    ['@fey.comment'] = '@comment',
    ['@fey.directive'] = '@comment',
    ['@fey.block'] = '@comment',

    -- Tags: each tag format keeps its own colour for the name, the head
    -- brackets/tokens and its body paragraphs
    ['@fey.tag.scope'] = '@fey.heading.level8',
    ['@fey.tag.block'] = '@fey.heading.level6',
    ['@fey.tag.line'] = '@fey.heading.level5',
    ['@fey.tag.pair'] = '@fey.heading.level4',
    ['@fey.tag.block.body'] = '@fey.tag.block',
    ['@fey.tag.line.body'] = '@fey.tag.line',
    ['@fey.tag.pair.body'] = '@fey.tag.pair',
    ['@fey.tag.delimiter'] = '@fey.color.gray',
    ['@fey.tag.value'] = '@fey.color.fg2',
    ['@fey.tag.key'] = '@fey.color.fg3',

    -- Other markup
    ['@fey.hyperlink'] = '@markup.link',
    ['@fey.hyperlink.url'] = '@markup.link.url',
    ['@fey.hyperlink.desc'] = '@markup.link.label',
    ['@fey.latex'] = '@markup.math',
    ['@fey.latex_env'] = '@markup.environment',
    ['@fey.footnote'] = '@markup.link.url',
    ['@fey.footnote.reference'] = '@markup.link.url',

    -- Other
    ['@fey.table.delimiter'] = '@punctuation.special',
    ['@fey.table.heading'] = '@markup.heading',
    ['@fey.edit_src'] = 'Visual',
  }

  for src, def in pairs(links) do
    if type(def) == 'table' then
      def.default = true
      vim.api.nvim_set_hl(0, src, def)
    else
      vim.api.nvim_set_hl(0, src, { link = def, default = true })
    end
  end
end

-- ---------------------------------------------------------------------------
-- Emphasis
--
--   single  `@fey.<name>`            double  `@fey.<name>.highlight`
--   each with a `.delimiter` variant (linked to its body group)
--
-- Names must match `markers` in fey.colors.highlighter.markup.emphasis.
-- ---------------------------------------------------------------------------
local STYLES = { 'underline', 'bold', 'italic', 'strikethrough' }

-- name -> { single fg colour, double background colour }
local COLORS = {
  red = { 'red', 'red' },
  orange = { 'orange', 'orange' },
  green = { 'green', 'green' },
  yellow = { 'yellow', 'yellow' },
  fuscia = { 'fuscia', 'fuscia' },
  blue = { 'blue', 'blue' },
  purple = { 'purple', 'purple' },
  teal = { 'teal', 'teal' },
  dim = { 'bg2', 'fg2' }, -- `+x+` fg bg2, `++x++` bg fg2
}

local function set(name, def)
  set_owned(name, def)
  vim.api.nvim_set_hl(0, name .. '.delimiter', { link = name, default = true })
end

-- "bg on colour" band: fg = editor background, bg = the given colour. With a
-- transparent background, fall back to reverse video of the colour.
local function band(color, ccolor, extra)
  local bg, cbg = normal_bg()
  local def = vim.tbl_extend('force', {}, extra or {})
  local cterm = vim.tbl_extend('force', {}, extra or {})
  if bg then
    def.fg, def.bg, def.ctermfg, def.ctermbg = bg, color, cbg, ccolor
  else
    def.fg, def.ctermfg = color, ccolor
    def.reverse, cterm.reverse = true, true
  end
  def.cterm = cterm
  return def
end

-- Resolved copy of a group plus a soft background.
local function on_soft_bg(group, extra)
  local def = vim.tbl_extend('force', get_hl(group) or {}, extra or {})
  def.bg, def.ctermbg = soft_bg()
  def.link = nil
  return def
end

function M.define_emphasis_highlights()
  local normal = get_hl('Normal') or {}

  -- `_x_` `!x!` `/x/` `~x~`  fg + style   /  doubled: bg on fg + style
  for _, style in ipairs(STYLES) do
    set('@fey.' .. style, { [style] = true, cterm = { [style] = true } })
    set('@fey.' .. style .. '.highlight', band(normal.fg, normal.ctermfg, { [style] = true }))
  end

  -- `$x$` ... `+x+`  coloured fg  /  doubled: bg on colour
  for name, c in pairs(COLORS) do
    set('@fey.' .. name, { link = '@fey.color.' .. c[1] })
    local hl = get_hl('@fey.color.' .. c[2]) or {}
    set('@fey.' .. name .. '.highlight', band(hl.fg, hl.ctermfg))
  end

  -- `` `x` `` code, `#x#` verbatim, `'x'` quote  /  doubled: on a soft band
  set('@fey.code', { link = '@markup.raw' })
  set('@fey.code.highlight', on_soft_bg('@markup.raw'))

  set('@fey.verbatim', { link = '@fey.color.fg3' })
  set('@fey.verbatim.highlight', on_soft_bg('@fey.color.fg3'))

  -- `.x.` `:x:` (and doubled): literal, but deliberately empty so the text
  -- shows the highlight of any outer emphasis. Still overridable.
  set('@fey.plain', {})
  set('@fey.plain.highlight', {})

  local quote = vim.tbl_extend('force', get_hl('@fey.color.fg2') or {}, { italic = true, cterm = { italic = true } })
  set('@fey.quote', quote)
  set('@fey.quote.highlight', on_soft_bg('@fey.color.fg2', { italic = true, cterm = { italic = true } }))
end

-- Re-derive the groups that copy colours from the colorscheme.
function M.refresh_colors()
  M.define_palette()
  M.define_emphasis_highlights()
end

-- Colours copied from the colorscheme go stale when it changes, and a
-- colorscheme loaded after fey (or loaded by calling its Lua directly, which
-- fires no ColorScheme event) would otherwise never be picked up. Refreshing
-- is cheap and set_owned() never touches overridden groups, so it also runs
-- once startup is done and whenever a fey buffer is opened.
function M.setup_autocmds()
  if M._autocmds then return end
  M._autocmds = true
  local group = vim.api.nvim_create_augroup('FeyHighlights', { clear = true })
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = group,
    callback = function() M.define_highlights() end,
  })
  vim.api.nvim_create_autocmd('VimEnter', {
    group = group,
    callback = M.refresh_colors,
  })
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = 'fey',
    callback = M.refresh_colors,
  })
end

function M.define_agenda_colors()
  local keyword_colors = colors.get_todo_keywords_colors()
  local c = {
    deadline = '@fey.agenda.deadline',
    upcoming_deadline = '@fey.agenda.deadline.upcoming',
    ok = '@fey.agenda.scheduled',
    warning = '@fey.agenda.scheduled_past',
  }
  for type, hlname in pairs(c) do
    vim.cmd(string.format('hi default %s guifg=%s ctermfg=%s', hlname, keyword_colors[type].gui, keyword_colors[type].cterm))
  end
  vim.cmd(
    ('hi default @fey.agenda.time_grid guifg=%s ctermfg=%s'):format(keyword_colors.warning.gui, keyword_colors.warning.cterm)
  )

  M.define_fey_todo_keyword_colors()
end

function M.define_fey_todo_keyword_colors()
  local keyword_colors = colors.get_todo_keywords_colors()
  vim.cmd(
    ('hi default @fey.keyword.todo guifg=%s ctermfg=%s gui=bold cterm=bold'):format(
      keyword_colors.TODO.gui,
      keyword_colors.TODO.cterm
    )
  )

  vim.cmd(
    ('hi default @fey.keyword.done guifg=%s ctermfg=%s gui=bold cterm=bold'):format(
      keyword_colors.DONE.gui,
      keyword_colors.DONE.cterm
    )
  )
  vim.cmd([[hi default @fey.leading_signature ctermfg=0 guifg=bg]])
end

function M.define_todo_keyword_faces()
  local opts = {
    underline = {
      type = vim.o.termguicolors and 'gui' or 'cterm',
      is_valid = function(value) return value == 'on' end,
      result = 'underline',
    },
    weight = {
      type = vim.o.termguicolors and 'gui' or 'cterm',
      is_valid = function(value) return value == 'bold' end,
    },
    foreground = {
      type = vim.o.termguicolors and 'guifg' or 'ctermfg',
      is_valid = function(value)
        if vim.o.termguicolors then return true end
        return value:sub(1, 1) ~= '#'
      end,
    },
    background = {
      type = vim.o.termguicolors and 'guibg' or 'ctermbg',
      is_valid = function(value)
        if vim.o.termguicolors then return true end
        return value:sub(1, 1) ~= '#'
      end,
    },
    slant = {
      type = vim.o.termguicolors and 'gui' or 'cterm',
      is_valid = function(value) return value == 'italic' end,
    },
  }

  local result = {}

  for name, values in pairs(config.fey_todo_keyword_faces) do
    local parts = vim.split(values, ':', { plain = true })
    local hl_opts = {}
    for _, part in ipairs(parts) do
      local faces = vim.split(vim.trim(part), ' ')
      if #faces == 2 then
        local opt_name = vim.trim(faces[1])
        local opt_value = vim.trim(faces[2])
        opt_value = opt_value:gsub('^"*', ''):gsub('"*$', '')
        local opt = opts[opt_name]
        if opt and opt.is_valid(opt_value) then
          if not hl_opts[opt.type] then hl_opts[opt.type] = {} end
          table.insert(hl_opts[opt.type], opt.result or opt_value)
        end
      end
    end
    if not vim.tbl_isempty(hl_opts) then
      local hl_name = '@fey.keyword.face.' .. name:gsub('%-', '')
      local hl = ''
      for hl_item, hl_values in pairs(hl_opts) do
        hl = hl .. ' ' .. hl_item .. '=' .. table.concat(hl_values, ',')
      end
      vim.cmd(string.format('hi default %s %s', hl_name, hl))
      result[name] = hl_name
    end
  end

  return result
end

---@return table<string, string>
function M.get_agenda_hl_map()
  local faces = M.define_todo_keyword_faces()
  return vim.tbl_extend('force', {
    TODO = '@fey.keyword.todo',
    DONE = '@fey.keyword.done',
    deadline = '@fey.agenda.deadline',
    upcoming_deadline = '@fey.agenda.deadline.upcoming',
    ok = '@fey.agenda.scheduled',
    warning = '@fey.agenda.scheduled_past',
    priority = config:get_priorities(),
  }, faces)
end

return M
