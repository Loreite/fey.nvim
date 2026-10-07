-- Write the Markdown of Fey files, for the pipeline that builds the help files (`scripts/build_docs.sh`):
--
--   nvim --headless --clean -l scripts/export_md.lua docs/index.fey docs/tutorial.fey ... > all.md
--
-- The files are written one after the other, to the standard output, each with a level one heading made of its title. The links to other docs
-- become links to anchors of this one document.
vim.opt.rtp:prepend(vim.fn.getcwd())
local parser = vim.env.FEY_PARSER
if parser then vim.treesitter.language.add('fey', { path = parser }) end
require('fey').setup({ fey_court_dir = vim.fn.tempname() .. '/court' })

local Export = require('fey.export')
local out = {}
for _, path in ipairs(arg) do
  local lines = vim.fn.readfile(path)
  local md = Export.markdown(table.concat(lines, '\n') .. '\n', { extension = 'md' })
  if md then
    -- the front matter is for a file of its own, the title goes on as a heading
    local title
    md = md:gsub('^%-%-%-\n(.-)\n%-%-%-\n', function(front)
      title = front:match('title: "(.-)"')
      return ''
    end)
    if title then
      -- the sections of the page go one level down, under the title of the page (not the lines inside fences)
      local lines, fenced = {}, false
      for line in vim.gsplit(md, '\n', { plain = true }) do
        if line:match('^```') or line:match('^~~~') then fenced = not fenced end
        lines[#lines + 1] = (not fenced and line:match('^#+ ')) and ('#' .. line) or line
      end
      md = table.concat(lines, '\n')
      out[#out + 1] = '# ' .. title .. '\n'
    end
    out[#out + 1] = md
  end
end
io.stdout:write(table.concat(out, '\n'))
vim.cmd('qa!')
