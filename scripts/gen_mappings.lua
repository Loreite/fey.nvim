-- Rewrite the list of default mappings in README.fey from the configuration.
--
--   nvim --headless -u NONE -l scripts/gen_mappings.lua            write
--   nvim --headless -u NONE -l scripts/gen_mappings.lua --check    exit 1 when README.fey is out of date
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(root)

local path = root .. '/README.fey'
local lines = vim.fn.readfile(path)
local new, err = require('fey.docs.mappings').replace(lines)
if new then new, err = require('fey.docs.checkboxes').replace(new) end
if not new then
  io.stderr:write('gen_mappings: ' .. err .. '\n')
  os.exit(1)
end
if vim.deep_equal(new, lines) then
  print('README.fey: mappings are up to date')
  os.exit(0)
end
if vim.tbl_contains(_G.arg or {}, '--check') then
  io.stderr:write('README.fey: the list of mappings is out of date, run scripts/gen_mappings.lua\n')
  os.exit(1)
end
vim.fn.writefile(new, path)
print('README.fey: mappings written')
