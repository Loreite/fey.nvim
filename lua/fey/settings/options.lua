-- Which options a note may set through the `nvim` tag. A note can come from anywhere, so this is a white list:
-- an option is set only when Neovim says it is local to the buffer or the window (`colorscheme` and
-- `background` are the two global ones) and it is not in the list of options that run code, call a function or
-- a program, or reach outside the editor. Those are denied until the user allows them by name in
-- `settings.allow`. Everything else is ignored, with a reason.
local M = {}

---Options that run what is in them: an expression, a function, a program, or that read and write files
---elsewhere. Even where Neovim's own modeline refuses them, a tag is applied on every change, so they are
---denied unless named in `settings.allow`.
---@type table<string, string>
M.UNSAFE = {
  -- expressions
  indentexpr = 'an expression',
  foldexpr = 'an expression',
  formatexpr = 'an expression',
  includeexpr = 'an expression',
  foldtext = 'an expression',
  balloonexpr = 'an expression',
  printexpr = 'an expression',
  diffexpr = 'an expression',
  patchexpr = 'an expression',
  charconvert = 'an expression',
  statusline = 'an expression',
  statuscolumn = 'an expression',
  tabline = 'an expression',
  winbar = 'an expression',
  rulerformat = 'an expression',
  -- functions
  omnifunc = 'a function',
  completefunc = 'a function',
  tagfunc = 'a function',
  thesaurusfunc = 'a function',
  quickfixtextfunc = 'a function',
  operatorfunc = 'a function',
  findfunc = 'a function',
  -- programs
  formatprg = 'a program',
  equalprg = 'a program',
  keywordprg = 'a program',
  makeprg = 'a program',
  grepprg = 'a program',
  shell = 'a program',
  shellcmdflag = 'a program',
  shellquote = 'a program',
  shellxquote = 'a program',
  shellredir = 'a program',
  shellpipe = 'a program',
  makeef = 'a program',
  -- the editor's own safety and files elsewhere
  modeline = 'the modeline switch',
  modelines = 'the modeline switch',
  modelineexpr = 'the modeline switch',
  exrc = 'loading local config',
  secure = 'a safety switch',
  undodir = 'a directory',
  backupdir = 'a directory',
  directory = 'a directory',
  viewdir = 'a directory',
  spellfile = 'a file',
  runtimepath = 'the runtime path',
  packpath = 'the runtime path',
  tags = 'a file',
}

---The global options a note may set (they change the whole editor while the note is current)
M.GLOBAL = { colorscheme = true, background = true }

---@class FeySettingOption
---@field name string
---@field scope 'buf'|'win'|'global'
---@field type string

---Is a name a Vim option, and where does it live
---@param name string
---@return FeySettingOption|nil
function M.info(name)
  if type(name) ~= 'string' or not name:match('^[%a]+$') then return nil end
  local ok, info = pcall(vim.api.nvim_get_option_info2, name, {})
  if not ok or not info then return nil end
  return { name = info.name, scope = info.scope, type = info.type }
end

---Whether an option can be set from a note, and if not why
---@param name string
---@param allow? string[]|table<string, boolean> names of unsafe options the user allows
---@return boolean ok
---@return string|nil reason
---@return FeySettingOption|nil info
function M.check(name, allow)
  if M.GLOBAL[name] then return true, nil, { name = name, scope = 'global', type = 'string' } end
  local info = M.info(name)
  if not info then return false, 'not an option' end
  local unsafe = M.UNSAFE[info.name]
  if unsafe then
    local allowed = false
    for k, v in pairs(allow or {}) do
      if (type(k) == 'number' and v == info.name) or (k == info.name and v == true) then allowed = true end
    end
    if not allowed then return false, ('%s is %s: denied, allow it in settings.allow'):format(info.name, unsafe) end
  end
  if info.scope == 'global' then return false, 'a global option' end
  return true, nil, info
end

---The value a tag gives, as the option wants it: a boolean, a number, or text (a list joins with commas)
---@param info FeySettingOption
---@param value any
---@return any
function M.coerce(info, value)
  if type(value) == 'table' then value = table.concat(vim.tbl_map(tostring, value), ',') end
  if info.type == 'boolean' then
    if value == true or value == 'true' or value == 'yes' or value == 'on' or value == 1 then return true end
    if value == false or value == 'false' or value == 'no' or value == 'off' or value == 0 then return false end
    return nil
  elseif info.type == 'number' then
    return tonumber(value)
  end
  return tostring(value)
end

return M
