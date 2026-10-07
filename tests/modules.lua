-- Every module of the plugin loads: no syntax error, no require of a module that is gone. Run from the repo root:
--
--   FEY_PARSER=/path/to/fey.so nvim --headless --clean -l tests/modules.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
if vim.env.FEY_PARSER then vim.treesitter.language.add('fey', { path = vim.env.FEY_PARSER }) end

-- modules that need something that is optional (a completion framework, a plugin of the user)
local OPTIONAL = {
  ['fey.fey.autocompletion.cmp'] = 'cmp',
  ['fey.fey.autocompletion.blink'] = 'blink',
}

local root = vim.fn.getcwd() .. '/lua/'
local files = vim.fn.globpath(root, 'fey/**/*.lua', true, true)
table.sort(files)
local failed, loaded, skipped = {}, 0, 0
require('fey').setup({ fey_court_dir = vim.fn.tempname() .. '/court' })
for _, file in ipairs(files) do
  local mod = file:sub(1, #root) == root and file:sub(#root + 1):match('^(.*)%.lua$')
  if mod then
    mod = mod:gsub('/', '.'):gsub('%.init$', '')
    if OPTIONAL[mod] and not pcall(require, OPTIONAL[mod]) then
      skipped = skipped + 1
    else
      local ok, err = pcall(require, mod)
      if ok then
        loaded = loaded + 1
      else
        failed[#failed + 1] = ('%s: %s'):format(mod, tostring(err):gsub('\n.*', ''))
      end
    end
  end
end
for _, f in ipairs(failed) do
  print('FAIL ' .. f)
end
print(('modules: %d loaded, %d skipped, %d failed'):format(loaded, skipped, #failed))
vim.cmd(#failed == 0 and 'qa!' or 'cq!')
