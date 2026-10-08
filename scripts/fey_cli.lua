-- The command line of Fey, run by `bin/fey` with `nvim --headless -l`:
--
--   fey import [--format markdown|org] [--write adjacent|replace|rename] [--force] [--dry-run] [--no-link-rewrite] FILE...
--   fey export --format markdown|html|latex|pdf|docx|odt|epub|rst|ics [--outdir DIR] [--force] FILE...
--
-- Set FEY_PARSER to the built fey parser when it is not where Neovim finds it, FEY_ORG_PARSER for the org one.
vim.opt.rtp:prepend(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h'))
local parser = vim.env.FEY_PARSER
if parser and parser ~= '' then vim.treesitter.language.add('fey', { path = parser }) end

local function out(s) io.stdout:write(s .. '\n') end
local function fail(s)
  io.stderr:write('fey: ' .. s .. '\n')
  vim.cmd('cquit 1')
end

local USAGE = [[
usage: fey import [options] FILE...
       fey export --format FORMAT [options] FILE...

import: Markdown (Obsidian's too) or org into Fey
  --format markdown|org      the format of the files (by default from the extension)
  --write adjacent|replace|rename
                             adjacent (default): write NAME.fey next to the source, keep the source
                             replace: write the Fey text over the file itself
                             rename: write over the file and give it the extension .fey
  --force                    write over a file that exists
  --dry-run                  convert and report, write nothing
  --no-link-rewrite          keep the .md and .org targets of links as they are
  --root DIR                 the directory of the vault: dataview queries (their FROM folders) and Database Folder views are converted
  --db-dir DIR               where the databases of those views are written (the `.fey/dbs` of the vault)

export: Fey into another format, always as a new file; the Fey file is kept
  --format FORMAT            markdown, html, ics, latex, pdf, docx, odt, epub or rst (pandoc writes all but the first three)
  --outdir DIR               write the files there, not next to the sources
  --force                    write over a file that exists

  --quiet                    print only the problems
]]

local args = arg
local command = table.remove(args, 1)
if not command or command == 'help' or command == '-h' or command == '--help' then
  io.stdout:write(USAGE)
  vim.cmd('qa!')
end
if command ~= 'import' and command ~= 'export' then fail('unknown command: ' .. command .. '\n' .. USAGE) end

local opts, files = {}, {}
local i = 1
while i <= #args do
  local a = args[i]
  local function value()
    i = i + 1
    if not args[i] then fail(a .. ' needs a value') end
    return args[i]
  end
  if a == '--format' or a == '-f' then
    opts.format = value()
  elseif a == '--write' or a == '-w' then
    opts.write = value()
  elseif a == '--outdir' or a == '-o' then
    opts.outdir = value()
  elseif a == '--force' then
    opts.force = true
  elseif a == '--dry-run' or a == '-n' then
    opts.dry_run = true
  elseif a == '--quiet' or a == '-q' then
    opts.quiet = true
  elseif a == '--root' then
    opts.root = value()
  elseif a == '--db-dir' then
    opts.db_dir = value()
  elseif a == '--no-link-rewrite' then
    opts.link_extension = false
  elseif a:sub(1, 2) == '--' then
    fail('unknown option: ' .. a)
  else
    files[#files + 1] = a
  end
  i = i + 1
end
if #files == 0 then fail('no files\n' .. USAGE) end

-- the plugin's configuration holds the names of the tags; the court is a temporary one so that nothing is made in the home directory
require('fey').setup({ fey_court_dir = vim.fn.tempname() .. '/court' })

local failed = 0
if command == 'import' then
  for _, result in ipairs(require('fey.import').files(files, opts)) do
    if result.err then
      failed = failed + 1
      io.stderr:write(('%s: %s\n'):format(result.source, result.err))
    elseif not opts.quiet then
      out(('%s -> %s%s'):format(result.source, result.target, opts.dry_run and ' (dry run)' or ''))
    end
    for _, w in ipairs(result.warnings) do
      io.stderr:write(('%s: %s\n'):format(result.source, w))
    end
  end
else
  if not opts.format then fail('export needs --format') end
  local Export = require('fey.export')
  for _, file in ipairs(files) do
    local target, err = Export.convert(opts.format, file, opts)
    if target then
      if not opts.quiet then out(('%s -> %s'):format(file, target)) end
    else
      failed = failed + 1
      io.stderr:write(('%s: %s\n'):format(file, err))
    end
  end
end
if failed > 0 then vim.cmd('cquit 1') end
vim.cmd('qa!')
