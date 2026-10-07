-- Import: Markdown (Obsidian's included) and org into Fey text. The walkers (`fey.import.markdown`, `fey.import.org`) read the tree of the
-- tree-sitter parsers into a document, and `fey.import.writer` writes it as Fey. This file is what is called: on a text, on a buffer (in place, one
-- undo step), and on files (next to the source, over it, or over it with the extension changed), one by one or as a batch. The command line is
-- `bin/fey import` (`fey.cli`).
local M = {}

---@alias FeyImportFormat 'markdown'|'org'

M.FORMATS = { 'markdown', 'org' }

local EXTENSIONS = { md = 'markdown', markdown = 'markdown', mdx = 'markdown', mkd = 'markdown', org = 'org' }
local FILETYPES = { markdown = 'markdown', org = 'org' }

---The format of a file or a buffer, from its name or its filetype
---@param path? string
---@param filetype? string
---@return FeyImportFormat|nil
function M.detect(path, filetype)
  local ext = path and path:match('%.([^./]+)$')
  if ext and EXTENSIONS[ext:lower()] then return EXTENSIONS[ext:lower()] end
  return filetype and FILETYPES[filetype] or nil
end

---@param name string
---@return FeyImportFormat|nil
local function normalize(name)
  name = (name or ''):lower()
  if name == 'md' or name == 'markdown' or name == 'obsidian' then return 'markdown' end
  if name == 'org' or name == 'orgmode' then return 'org' end
end
M.normalize = normalize

---The line of the first syntax error of a Fey text, if the Fey parser is there
---@param text string
---@return integer|nil line 1 based
local function first_error(text)
  local ok, parser = pcall(vim.treesitter.get_string_parser, text, 'fey')
  if not ok then return nil end
  local root = parser:parse()[1]:root()
  if not root:has_error() then return nil end
  local found
  local function walk(node)
    if found then return end
    if node:type() == 'ERROR' or node:missing() then
      found = (node:range()) + 1
      return
    end
    for child in node:iter_children() do
      if child:has_error() or child:missing() or child:type() == 'ERROR' then walk(child) end
      if found then return end
    end
  end
  walk(root)
  return found
end

---Fey text from a Markdown or org text
---@param src string
---@param format FeyImportFormat
---@param opts? { link_extension?: boolean, parser?: string, check?: boolean } `link_extension` (default true) turns links to `.md` and `.org` files into links to `.fey` files; `check` (default true) reads the result back and warns about syntax errors
---@return string|nil text
---@return string[]|string warnings the things that did not come across, or the reason for the failure when there is no text
function M.text(src, format, opts)
  opts = opts or {}
  format = normalize(format)
  -- files from Windows: a byte order mark and carriage returns
  src = src:gsub('^\239\187\191', ''):gsub('\r\n?', '\n')
  local doc, err
  if format == 'markdown' then
    for _, lang in ipairs({ 'markdown', 'markdown_inline' }) do
      local ok, res = pcall(vim.treesitter.language.add, lang)
      if not (ok and res) then
        return nil, ('the tree-sitter parser for %s is not installed (nvim-treesitter installs it)'):format(lang)
      end
    end
    doc = require('fey.import.markdown').parse(src, opts)
  elseif format == 'org' then
    doc, err = require('fey.import.org').parse(src, opts)
  else
    return nil, 'unknown format: ' .. tostring(format)
  end
  if not doc then return nil, err end
  local text, warnings = require('fey.import.writer').render(doc)
  if opts.check ~= false then
    local line = first_error(text)
    if line then warnings[#warnings + 1] = ('the result has a syntax error near line %d'):format(line) end
  end
  return text, warnings
end

---Change a buffer from Markdown or org to Fey, in place. One undo step undoes it.
---@param bufnr? integer
---@param format? FeyImportFormat by default the one the file name or the filetype says
---@param opts? { rename?: boolean, link_extension?: boolean }
---@return boolean ok
---@return string[]|string warnings
function M.buffer(bufnr, format, opts)
  opts = opts or {}
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local name = vim.api.nvim_buf_get_name(bufnr)
  format = normalize(format or '') or M.detect(name, vim.bo[bufnr].filetype)
  if not format then return false, 'the format is not known: pass markdown or org' end
  local src = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n') .. '\n'
  local text, warnings = M.text(src, format, opts)
  if not text then return false, warnings end
  local lines = vim.split(text, '\n', { plain = true })
  if lines[#lines] == '' then lines[#lines] = nil end
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].filetype = 'fey'
  if opts.rename and name ~= '' then
    local target = name:gsub('%.[^./]+$', '') .. '.fey'
    vim.api.nvim_buf_call(bufnr, function() vim.cmd('silent! file ' .. vim.fn.fnameescape(target)) end)
  end
  return true, warnings
end

---Where the Fey file of a source goes
---@param path string
---@param mode 'adjacent'|'replace'|'rename'
---@return string target
function M.target(path, mode)
  if mode == 'replace' then return path end
  return (path:gsub('%.[^./\\]+$', '')) .. '.fey'
end

local function read(path)
  local fh, err = io.open(path, 'rb')
  if not fh then return nil, err end
  local data = fh:read('*a')
  fh:close()
  return data
end

local function write(path, content)
  local fh, err = io.open(path, 'wb')
  if not fh then return false, err end
  fh:write(content)
  fh:close()
  return true
end

---@class FeyImportResult
---@field source string
---@field target? string
---@field warnings string[]
---@field err? string

---Import a file. `adjacent` (the default) writes `name.fey` next to the source and leaves the source alone; `replace` writes the Fey text over the
---file itself; `rename` writes over the file and gives it the extension `.fey`.
---@param path string
---@param opts? { format?: string, write?: 'adjacent'|'replace'|'rename', force?: boolean, dry_run?: boolean, link_extension?: boolean }
---@return FeyImportResult
function M.file(path, opts)
  opts = opts or {}
  local result = { source = path, warnings = {} }
  local format = normalize(opts.format or '') or M.detect(path)
  if not format then
    result.err = 'the format is not known (the extension is not md, markdown or org): pass --format'
    return result
  end
  local mode = opts.write or 'adjacent'
  if mode ~= 'adjacent' and mode ~= 'replace' and mode ~= 'rename' then
    result.err = 'unknown write mode: ' .. tostring(mode)
    return result
  end
  local src, err = read(path)
  if not src then
    result.err = err
    return result
  end
  local text, warnings = M.text(src, format, opts)
  if not text then
    result.err = type(warnings) == 'string' and warnings or 'the import failed'
    return result
  end
  result.warnings = warnings
  local target = M.target(path, mode == 'replace' and 'replace' or mode == 'rename' and 'rename' or 'adjacent')
  result.target = target
  if mode == 'adjacent' and vim.uv.fs_stat(target) and not opts.force then
    result.err = 'the file exists: ' .. target .. ' (pass --force to write over it)'
    return result
  end
  if mode == 'rename' and target ~= path and vim.uv.fs_stat(target) and not opts.force then
    result.err = 'the file exists: ' .. target .. ' (pass --force to write over it)'
    return result
  end
  if opts.dry_run then return result end
  local ok, werr = write(target, text)
  if not ok then
    result.err = werr
    return result
  end
  if mode == 'rename' and target ~= path then os.remove(path) end
  return result
end

---Import many files; one that fails does not stop the others
---@param paths string[]
---@param opts? table as for `file`
---@return FeyImportResult[]
function M.files(paths, opts)
  local results = {}
  for _, path in ipairs(paths) do
    results[#results + 1] = M.file(path, opts)
  end
  return results
end

-- the command -----------------------------------------------------------------------------------------------------------------

function M.setup()
  vim.api.nvim_create_user_command('FeyImport', function(cmd)
    local format, rename
    for _, arg in ipairs(cmd.fargs) do
      if arg == 'rename' then
        rename = true
      else
        format = arg
      end
    end
    local ok, warnings = M.buffer(0, format, { rename = rename })
    local utils = require('fey.utils')
    if not ok then return utils.echo_error('Import: ' .. tostring(warnings)) end
    if #warnings > 0 then
      utils.echo_warning('Imported, with notes:\n' .. table.concat(warnings, '\n'))
    else
      utils.echo_info('Imported')
    end
  end, {
    nargs = '*',
    complete = function() return { 'markdown', 'org', 'rename' } end,
    desc = 'Change this buffer from Markdown or org to Fey, in place (one undo step); `rename` also gives it the .fey name',
  })
  vim.api.nvim_create_user_command('FeyExport', function(cmd)
    local format = cmd.args ~= '' and cmd.args or nil
    if not format then return require('fey.export').prompt() end
    require('fey.export').file(format)
  end, {
    nargs = '?',
    complete = function() return { 'markdown', 'html', 'ics', 'latex', 'pdf', 'docx', 'odt', 'epub', 'rst' } end,
    desc = 'Export this note to a file next to it (the note is kept); without a format, a menu',
  })
end

return M
