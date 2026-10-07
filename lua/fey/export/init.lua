-- Export. The Lua exporter walks the tree itself (`fey.export.model`) and writes Markdown or HTML, so those need nothing installed;
-- every other format (LaTeX, PDF, Word, EPUB, ...) is pandoc reading that Markdown. An iCalendar file comes from the dates in the
-- index. `fey_custom_exports` adds entries to the menu.
local utils = require('fey.utils')
local config = require('fey.config')
local Menu = require('fey.ui.menu')

---@class FeyExport
local Export = {}

---@param cmd table
---@param target string
---@param on_success? function
---@param on_error? function
function Export._exporter(cmd, target, on_success, on_error)
  utils.echo_info('Exporting...')
  local output = {}
  local read_data = function(_, data, _)
    for _, i in ipairs(data) do
      if i and i ~= '' then table.insert(output, i) end
    end
  end
  vim.fn.jobstart(cmd, {
    on_stdout = read_data,
    on_stderr = read_data,
    on_exit = function(_, code, _)
      if code ~= 0 then
        if on_error then return on_error(output) end
        return utils.echo_error(string.format('Export error:\n%s', table.concat(output, '\n')))
      end
      if on_success then return on_success(output) end
      return Export.done(target)
    end,
  })
end

---Say where the file went and offer to open it
---@param target string
function Export.done(target)
  local menu = Menu:new({ title = string.format('Exported to %s', target), prompt = 'Open?' })
  menu:add_separator({ length = 34 })
  menu:add_option({ label = 'Yes', key = 'y', action = function() return vim.ui.open(target) end })
  menu:add_option({ label = 'No', key = 'n' })
  return menu:open()
end

---Give a tag of your own an export (see `fey.export.tags`): `Export.tag('note', { block_tag = [[<aside>\n%s\n</aside>]] })`
---@param name string
---@param spec table|string|function
function Export.tag(name, spec) require('fey.export.tags').add(name, spec) end

---@param bufnr? integer
---@return string text
---@return string path
local function source_of(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n') .. '\n', vim.api.nvim_buf_get_name(bufnr)
end

---The Markdown of a text
---@param src string
---@param opts? { extension?: string } what the links to other notes end with
---@return string|nil markdown nil when everything is commented
function Export.markdown(src, opts)
  local doc = require('fey.export.model').parse(src, opts)
  return doc and require('fey.export.markdown').render(doc) or nil
end

---The HTML page of a text
---@param src string
---@param opts? { extension?: string }
---@return string|nil html nil when everything is commented
function Export.html(src, opts)
  local doc = require('fey.export.model').parse(src, vim.tbl_extend('keep', opts or {}, { extension = 'html' }))
  return doc and require('fey.export.html').render(doc) or nil
end

---The iCalendar file of the dates of a file, from the index
---@param path string absolute path of the file
---@return string|nil
function Export.ics(path)
  local fey_vault = require('fey.vault')
  local vault = fey_vault.for_path(path)
  local rel = vault and vault:rel_of(path)
  if not vault or not vault.db or not rel then return nil end
  local rows = vault:dates({ path = rel, kinds = { 'scheduled', 'deadline', 'date' } })
  return require('fey.export.ics').render(rows, { name = vim.fn.fnamemodify(path, ':t:r') })
end

---@param target string
---@param content string
local function write(target, content)
  local ok = vim.fn.writefile(vim.split(content, '\n', { plain = true }), target, 'b')
  return ok == 0
end

-- what the formats are: the extension, how it is made
local PANDOC = {
  latex = { extension = 'tex', to = 'latex' },
  pdf = { extension = 'pdf', to = 'pdf' },
  docx = { extension = 'docx', to = 'docx' },
  odt = { extension = 'odt', to = 'odt' },
  epub = { extension = 'epub', to = 'epub' },
  rst = { extension = 'rst', to = 'rst' },
}

---Export a buffer to a file next to it
---@param format 'markdown'|'html'|'ics'|'latex'|'pdf'|'docx'|'odt'|'epub'|'rst'
---@param bufnr? integer
---@return string|nil target
function Export.file(format, bufnr)
  local src, path = source_of(bufnr)
  if path == '' then
    utils.echo_error('Export: the buffer has no file')
    return nil
  end
  local base = vim.fn.fnamemodify(path, ':p:r')
  if format == 'ics' then
    local content = Export.ics(vim.fn.fnamemodify(path, ':p'))
    if not content then
      utils.echo_error('Export: the file is not in an indexed hollow')
      return nil
    end
    local target = base .. '.ics'
    write(target, content)
    Export.done(target)
    return target
  end
  if format == 'markdown' or format == 'html' then
    local content = Export[format](src)
    if not content then
      utils.echo_warning('Nothing to export: everything is commented')
      return nil
    end
    local target = base .. (format == 'markdown' and '.md' or '.html')
    write(target, content)
    Export.done(target)
    return target
  end
  local spec = PANDOC[format]
  if not spec then
    utils.echo_error('Export: unknown format ' .. tostring(format))
    return nil
  end
  if vim.fn.executable('pandoc') ~= 1 then
    utils.echo_error('pandoc executable not found. Make sure pandoc is in $PATH.')
    return nil
  end
  local content = Export.markdown(src, { extension = spec.extension })
  if not content then
    utils.echo_warning('Nothing to export: everything is commented')
    return nil
  end
  local middle = vim.fn.tempname() .. '.md'
  write(middle, content)
  local target = base .. '.' .. spec.extension
  Export._exporter({ 'pandoc', middle, '-f', 'gfm+tex_math_dollars+footnotes', '-s', '-o', target }, target)
  return target
end

---Export a file to a file of another kind, with nothing asked and nothing shown (for the command line and for scripts). The note is always kept: the
---result is `name.<extension>` next to it, or in `opts.outdir`. pandoc formats wait for pandoc to finish.
---@param format 'markdown'|'html'|'ics'|'latex'|'pdf'|'docx'|'odt'|'epub'|'rst'
---@param path string the Fey file
---@param opts? { outdir?: string, force?: boolean }
---@return string|nil target
---@return string|nil err
function Export.convert(format, path, opts)
  opts = opts or {}
  path = vim.fn.fnamemodify(path, ':p')
  local fh, ferr = io.open(path, 'rb')
  if not fh then return nil, ferr end
  local src = fh:read('*a')
  fh:close()
  local stem = vim.fn.fnamemodify(path, ':t:r')
  local dir = opts.outdir and vim.fn.fnamemodify(opts.outdir, ':p'):gsub('/$', '') or vim.fn.fnamemodify(path, ':h')
  if opts.outdir then vim.fn.mkdir(dir, 'p') end
  local ext = ({ markdown = 'md', html = 'html', ics = 'ics' })[format] or (PANDOC[format] and PANDOC[format].extension)
  if not ext then return nil, 'unknown format: ' .. tostring(format) end
  local target = dir .. '/' .. stem .. '.' .. ext
  if vim.uv.fs_stat(target) and not opts.force then
    return nil, 'the file exists: ' .. target .. ' (pass --force to write over it)'
  end
  if format == 'ics' then
    local content = Export.ics(path)
    if not content then return nil, 'the file is not in an indexed hollow, the dates come from the index' end
    if write(target, content) then return target end
    return nil, 'could not write ' .. target
  end
  if format == 'markdown' or format == 'html' then
    local content = Export[format](src)
    if not content then return nil, 'nothing to export: everything is commented' end
    if write(target, content) then return target end
    return nil, 'could not write ' .. target
  end
  if vim.fn.executable('pandoc') ~= 1 then return nil, 'pandoc executable not found. Make sure pandoc is in $PATH.' end
  local content = Export.markdown(src, { extension = ext })
  if not content then return nil, 'nothing to export: everything is commented' end
  local middle = vim.fn.tempname() .. '.md'
  write(middle, content)
  local res = vim
    .system({ 'pandoc', middle, '-f', 'gfm+tex_math_dollars+footnotes', '-s', '-o', target }, { text = true })
    :wait()
  os.remove(middle)
  if res.code ~= 0 then return nil, 'pandoc failed: ' .. vim.trim(res.stderr or '') end
  return target
end

---Export the files of a hollow that have a label, each next to its source, as Markdown or HTML
---@param label string
---@param format 'markdown'|'html'
---@param root? string root of the hollow, by default the one of the buffer
---@return string[] targets
function Export.label(label, format, root)
  local fey_vault = require('fey.vault')
  local vault = root and fey_vault.open(root) or fey_vault.for_path(vim.api.nvim_buf_get_name(0)) or fey_vault.current()
  local targets = {}
  if not vault or not vault.db then return targets end
  for _, file in ipairs(vault:files_with_label(label)) do
    local abs = vault:abs(file.path)
    local fh = io.open(abs, 'rb')
    if fh then
      local src = fh:read('*a')
      fh:close()
      local content = Export[format](src)
      if content then
        local target = vim.fn.fnamemodify(abs, ':r') .. (format == 'markdown' and '.md' or '.html')
        write(target, content)
        targets[#targets + 1] = target
      end
    end
  end
  return targets
end

function Export.prompt()
  local items = {
    { label = 'Export to Markdown file', key = 'm', action = function() return Export.file('markdown') end },
    { label = 'Export to HTML file', key = 'h', action = function() return Export.file('html') end },
    { label = 'Export to iCalendar file (dates)', key = 'i', action = function() return Export.file('ics') end },
    { label = 'Export to LaTeX file (pandoc)', key = 'l', action = function() return Export.file('latex') end },
    { label = 'Export to PDF file (pandoc)', key = 'p', action = function() return Export.file('pdf') end },
    { label = 'Export to Word file (pandoc)', key = 'd', action = function() return Export.file('docx') end },
    { label = 'Export to OpenDocument file (pandoc)', key = 'o', action = function() return Export.file('odt') end },
    { label = 'Export to EPUB file (pandoc)', key = 'e', action = function() return Export.file('epub') end },
  }
  for key, data in utils.sorted_pairs(config.fey_custom_exports or {}) do
    table.insert(items, { key = key, label = data.label, action = function() return data.action(Export._exporter) end })
  end
  table.insert(items, { label = 'quit', key = 'q' })
  table.insert(items, { icon = ' ', length = 1 })
  return Menu:new({ title = 'Export options', items = items, prompt = 'Export command' }):open()
end

return Export
