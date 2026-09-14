local files = {
  'lua/fey/api/init.lua',
  'lua/fey/api/file.lua',
  'lua/fey/api/heading.lua',
  'lua/fey/api/agenda.lua',
  'lua/fey/api/position.lua',
}
local destination = 'doc/fey_api.txt'

vim.fn.system(('lemmy-help %s > %s'):format(table.concat(files, ' '), destination))
vim.cmd([[qa!]])
