-- Obsidian plugin blocks in the Fey text an import made: a fenced `dataview` query becomes a `query` block tag, a `yaml:dbfolder` view (the Database Folder
-- plugin) becomes a database file and a `feydb` tag that shows it.
--
-- Both are found as source blocks (`###  src dataview` ... `###`) in the text, so this works on the text of any import, and on the text of notes that were
-- imported before. The folders that queries read from are mapped from the names of the vault they come from by `opts.folders`.
local M = {}

local markdown = require('fey.import.markdown')

---@class FeyObsidianOpts
---@field root? string directory of the vault: folder names in queries are looked up in it
---@field db_dir? string where the database files go (`.fey/dbs` of the vault); without it no database is written and the block stays
---@field folders? table<string, string> the first directory of an old path -> the directory it is now (default: the archive's)

local DEFAULT_FOLDERS = {
  lPbteyo = 'internal',
  RAkTI = 'external',
  zeyUlin = 'meta',
  zEyulin = 'meta',
  zEyulicAnA = 'meta',
  Laebteo = 'internal',
  ['Dzoung Laebteo'] = 'internal',
  ARCH_IVE = 'arch_ive',
  Campus = 'arch_ive',
}

local function is_dir(path)
  local st = vim.uv.fs_stat(path)
  return st ~= nil and st.type == 'directory'
end

---The directory a folder of a query is now in, or nil
---@param old string `lPbteyo/Games_/src`
---@param opts FeyObsidianOpts
---@return string|nil
function M.folder(old, opts)
  old = old:gsub('^/', ''):gsub('/$', '')
  if old == '' or not opts.root then return nil end
  local parts = vim.split(old, '/', { plain = true })
  local top = (opts.folders or DEFAULT_FOLDERS)[parts[1]]
  if not top or not is_dir(vim.fs.joinpath(opts.root, top)) then return nil end
  local at = top
  local rest = vim.list_slice(parts, 2)
  if #rest == 0 then return at end
  -- the second name has a `_` where the directory has a prefix and a space: `Games_` is `DEV-GAME Games`, `Betterment_Journals_` is `BET-JRNL Journals`
  local want = rest[1]:gsub('_$', ''):gsub('^_', '')
  local words = vim.split(want, '_', { plain = true })
  local last = words[#words]
  local function find(dir)
    local full = vim.fs.joinpath(opts.root, dir)
    if not is_dir(full) then return nil end
    local best
    for name, kind in vim.fs.dir(full) do
      if kind == 'directory' and (name == want or name:match(' ' .. vim.pesc(last) .. '$') or name:match(' ' .. vim.pesc((want:gsub('_', ' '))) .. '$')) then
        best = best or name
      end
    end
    return best and vim.fs.joinpath(dir, best)
  end
  at = find(at) or find(at .. '/transfer')
  if not at then return nil end
  local tail = table.concat(vim.list_slice(rest, 2), '/')
  if tail == '' then return at end
  for _, base in ipairs({ at, at .. '/transfer' }) do
    if is_dir(vim.fs.joinpath(opts.root, base, tail)) then return vim.fs.joinpath(base, tail) end
  end
  return nil
end

---Names of properties the import writes with an underscore (`arch-ive-path` is `arch_ive_path`)
local function properties_of(expr) return (expr:gsub('(%a[%w_]*)%-(%a[%w_%-]*)', function(a, b)
  local word = a .. '-' .. b
  if a:lower() == 'arch' and b:match('^ive') then return (word:gsub('%-', '_')) end
  return nil
end)) end

---@param query string
---@param opts FeyObsidianOpts
---@param warn fun(msg: string)
---@return string
function M.query(query, opts, warn)
  query = query:gsub('[Ff][Rr][Oo][Mm]%s+"([^"]*)"', function(path)
    if path == '' or path == '/' then return nil end
    local new = M.folder(path, opts)
    if new then return 'FROM "' .. new .. '"' end
    warn('the folder of a query was not found: ' .. path)
    return nil
  end)
  return properties_of(query)
end

-- dbfolder ------------------------------------------------------------------------------------------------------------------

local SPECIAL = {
  __file__ = 'file.name',
  __inlinks__ = 'file.inlinks',
  __outlinks__ = 'file.outlinks',
  __created__ = 'file.ctime',
  __modified__ = 'file.mtime',
}

local OPS = {
  EQUAL = 'eq',
  NOT_EQUAL = 'ne',
  CONTAINS = 'contains',
  NOT_CONTAINS = 'notcontains',
  STARTS_WITH = 'startswith',
  ENDS_WITH = 'endswith',
  IS_EMPTY = 'empty',
  IS_NOT_EMPTY = 'notempty',
  GREATER_THAN = 'gt',
  GREATER_THAN_OR_EQUAL = 'ge',
  LESS_THAN = 'lt',
  LESS_THAN_OR_EQUAL = 'le',
}

local function typed(v)
  if v == 'true' then return true end
  if v == 'false' then return false end
  if type(v) == 'string' and v:match('^%-?%d+%.?%d*$') then return tonumber(v) end
  return v
end

local function field(node, key)
  if type(node) ~= 'table' or not node.map then return nil end
  for _, kv in ipairs(node.map) do
    if kv[1] == key then return kv[2] end
  end
end

---The database a dbfolder view describes (see `fey.db.store` for the shape)
---@param yaml string the body of the `yaml:dbfolder` block
---@param opts FeyObsidianOpts
---@param warn fun(msg: string)
---@return table|nil base
function M.dbfolder(yaml, opts, warn)
  local root = markdown.parse_yaml(yaml)
  if not root then return nil end
  local base = { name = field(root, 'name'), version = 1 }
  local description = field(root, 'description')
  if type(description) == 'string' and description ~= '' then base.description = description end

  local cols = {}
  local columns = field(root, 'columns')
  for n, kv in ipairs(columns and columns.map or {}) do
    local c = kv[2]
    local key = type(field(c, 'key')) == 'string' and field(c, 'key') or kv[1]
    local hidden = field(c, 'isHidden') == 'true'
    local input = field(c, 'input')
    if not hidden then
      local prop = SPECIAL[key] or markdown.key_of(key)
      local col = { prop = prop }
      local label = field(c, 'label')
      if type(label) == 'string' and label ~= '' and label ~= key then col.display = label end
      local width = tonumber(field(c, 'width') or '')
      -- Database Folder measures a column in pixels, a view of Fey in characters
      if width then col.width = math.max(math.floor(width / 8 + 0.5), 6) end
      cols[#cols + 1] = { col = col, pos = tonumber(field(c, 'position') or '') or n, n = n }
    end
    if key == '__tasks__' or input == 'tasks' then warn('a column of tasks has no database column') end
  end
  table.sort(cols, function(a, b)
    if a.pos ~= b.pos then return a.pos < b.pos end
    return a.n < b.n
  end)
  local view = { name = 'Table', type = 'table', columns = {}, row_height = 1, freeze = 1 }
  for _, c in ipairs(cols) do
    view.columns[#view.columns + 1] = c.col
  end
  base.views = { view }

  -- where the rows come from, and the filters
  local config = field(root, 'config')
  local source = type(field(config, 'source_form_result')) == 'string' and field(config, 'source_form_result') or ''
  local items = {}
  local from, rest = source:match('^%s*FROM%s+"([^"]*)"%s*(.-)%s*$')
  if from and from ~= '' and from ~= '/' then
    local new = M.folder(from, opts)
    if new then
      items[#items + 1] = { kind = 'cond', prop = 'file.path', op = 'infolder', value = new }
    else
      warn('the folder of a view was not found: ' .. from)
    end
  end
  local where = rest and rest:match('^WHERE%s+(.+)$')
  if where then items[#items + 1] = { kind = 'expr', expr = properties_of(where):gsub('%s+AND%s+', ' and '):gsub('%s+OR%s+', ' or ') } end
  if source ~= '' and not from then warn('the source of a view was not understood: ' .. source) end

  local filters = field(root, 'filters')
  local conditions = field(filters, 'conditions')
  for _, group in ipairs(conditions and conditions.list or {}) do
    local gitems = {}
    local list = field(group, 'filters')
    for _, f in ipairs(list and list.list or {}) do
      local op = OPS[field(f, 'operator') or '']
      local prop = field(f, 'field')
      if op and prop and field(f, 'disabled') ~= 'true' then
        gitems[#gitems + 1] = { kind = 'cond', prop = SPECIAL[prop] or markdown.key_of(prop), op = op, value = field(f, 'value') or '' }
      elseif op == nil then
        warn('a filter operator has no equivalent: ' .. tostring(field(f, 'operator')))
      end
    end
    if #gitems > 0 then
      items[#items + 1] = { kind = 'group', mode = (field(group, 'condition') or 'AND'):lower() == 'or' and 'or' or 'and', items = gitems }
    end
  end
  if #items > 0 and field(filters, 'enabled') ~= 'false' then base.filters = { kind = 'group', mode = 'and', items = items } end
  return base
end

-- text ----------------------------------------------------------------------------------------------------------------------

---The source blocks of a text: `###  src lang` ... `###`, with the text between
local function blocks(lines)
  local out, i = {}, 1
  while i <= #lines do
    local lang = lines[i]:match('^###  src ([%w:_%-]+)%s*$')
    if lang then
      local j = i + 1
      while lines[j] and lines[j] ~= '###' do
        j = j + 1
      end
      if lines[j] then out[#out + 1] = { from = i, to = j, lang = lang } end
      i = j
    end
    i = i + 1
  end
  return out
end

local function unique_name(dir, name)
  local store = require('fey.db.store')
  local base = store.sanitize(name)
  local n, try = 1, base
  while vim.uv.fs_stat(vim.fs.joinpath(dir, try .. '.fey')) do
    n = n + 1
    try = ('%s (%d)'):format(base, n)
  end
  return try
end

---Dataview queries and dbfolder views of a Fey text
---@param text string
---@param opts? FeyObsidianOpts
---@return string text
---@return string[] warnings
---@return string[] written the database files that were written
function M.fix_text(text, opts)
  opts = opts or {}
  local warnings, written = {}, {}
  local function warn(m)
    if not vim.tbl_contains(warnings, m) then warnings[#warnings + 1] = m end
  end
  local lines = vim.split(text, '\n', { plain = true })
  local found = blocks(lines)
  for n = #found, 1, -1 do
    local b = found[n]
    local body = vim.list_slice(lines, b.from + 1, b.to - 1)
    local replacement
    if b.lang == 'dataview' then
      local q = M.query(table.concat(body, '\n'), opts, warn)
      replacement = { '[ query ]#' }
      for _, l in ipairs(vim.split(vim.trim(q), '\n', { plain = true })) do
        replacement[#replacement + 1] = l == '' and '' or ('   ' .. l)
      end
    elseif b.lang == 'yaml:dbfolder' then
      local base = M.dbfolder(table.concat(body, '\n'), opts, warn)
      if base and opts.db_dir then
        vim.fn.mkdir(opts.db_dir, 'p')
        local name = unique_name(opts.db_dir, base.name or 'database')
        base.name = name
        local ok, data = pcall(require('fey.db.serialize').encode, base)
        if ok then
          local fh = io.open(vim.fs.joinpath(opts.db_dir, name .. '.fey'), 'wb')
          if fh then
            fh:write(data)
            fh:close()
            written[#written + 1] = name
            replacement = { ('{# feydb, 10; db: %s #}'):format(name) }
          end
        else
          warn('a database view could not be written: ' .. tostring(data))
        end
      end
    end
    if replacement then
      for _ = b.from, b.to do
        table.remove(lines, b.from)
      end
      for k, l in ipairs(replacement) do
        table.insert(lines, b.from + k - 1, l)
      end
    end
  end
  return table.concat(lines, '\n'), warnings, written
end

return M
