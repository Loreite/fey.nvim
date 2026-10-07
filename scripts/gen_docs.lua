-- Write the generated parts of the docs (`docs/*.fey`) from the code: the reference of the options, the options a note may not set, the reference of the
-- tags, the list of mappings, the changelog.
--
--   nvim --headless --clean -l scripts/gen_docs.lua            write
--   nvim --headless --clean -l scripts/gen_docs.lua --check    exit 1 when a part is out of date
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(root)
if vim.env.FEY_PARSER then vim.treesitter.language.add('fey', { path = vim.env.FEY_PARSER }) end

local generated = require('fey.docs.generated')

---@type { file: string, name: string, volatile?: boolean, body: fun(): string[] }[]
local PARTS = {
  { file = 'docs/configuration.fey', name = 'options', body = function() return require('fey.docs.options').render() end },
  { file = 'docs/configuration.fey', name = 'denied', body = function() return require('fey.docs.options').render_denied() end },
  { file = 'docs/tags.fey', name = 'tags', body = function() return require('fey.docs.tags').render() end },
  { file = 'docs/mappings.fey', name = 'mappings', body = function() return require('fey.docs.mappings').render_for_docs() end },
  { file = 'docs/changelog.fey', name = 'changelog', volatile = true, body = function() return require('fey.docs.changelog').render() end },
}

local check = vim.tbl_contains(_G.arg or {}, '--check')
local stale, written = {}, 0
local by_file = {}
for _, part in ipairs(PARTS) do
  by_file[part.file] = by_file[part.file] or {}
  table.insert(by_file[part.file], part)
end
local files = vim.tbl_keys(by_file)
table.sort(files)
for _, file in ipairs(files) do
  local path = root .. '/' .. file
  local lines = vim.fn.readfile(path)
  local original = lines
  local volatile_only = true
  for _, part in ipairs(by_file[file]) do
    if not (check and part.volatile) then volatile_only = false end
    local new, err = generated.replace(lines, part.name, part.body())
    if not new then
      io.stderr:write(('gen_docs: %s: %s\n'):format(file, err))
      os.exit(1)
    end
    lines = new
  end
  -- the changelog changes with every commit: it is written, not checked
  if not vim.deep_equal(lines, original) and not (check and volatile_only) then
    stale[#stale + 1] = file
    if not check then
      vim.fn.writefile(lines, path)
      written = written + 1
    end
  end
end

if check and #stale > 0 then
  io.stderr:write('gen_docs: out of date, run scripts/gen_docs.lua: ' .. table.concat(stale, ', ') .. '\n')
  os.exit(1)
end
print(written > 0 and ('gen_docs: wrote %d file%s'):format(written, written == 1 and '' or 's') or 'gen_docs: the docs are up to date')
