local h = vim.health

local M = {}

function M.check()
  h.start('Fey')
  M.check_has_treesitter()
  M.check_setup()
  M.check_options()
  M.check_vaults()
  M.check_shellslash()
end

---Options that are not options, that have the wrong type or that are gone
function M.check_options()
  local problems = require('fey.config.validate').check(require('fey').setup_options(), require('fey.config.defaults'))
  if #problems == 0 then return h.ok('the options of `setup` are fine') end
  h.warn(
    ('%d problem%s with the options of `setup`'):format(#problems, #problems == 1 and '' or 's'),
    vim.tbl_map(function(p) return p.message end, problems)
  )
end

---The names of the tags that mean something: the plugin's, the exports and handlers of the user, HTML elements, the data tags
---@return table<string, boolean>
local function known_tag_names()
  local config = require('fey.config')
  local known = { table = true, array = true, value = true, label = true }
  for key, value in pairs(config.opts) do
    if type(key) == 'string' and key:match('^fey_.*_tag_name$') and type(value) == 'string' then known[value] = true end
  end
  for name in pairs(config.tag_exports or {}) do
    known[name] = true
  end
  for name in pairs(require('fey.export.tags').registry) do
    known[name] = true
  end
  for name in pairs(require('fey.files.elements.tags').handlers or {}) do
    known[name] = true
  end
  for name in pairs(require('fey.export.tags').HTML_ELEMENTS) do
    known[name] = true
    known[name .. '_'] = true
  end
  return known
end

---The index of every hollow of the court: its state, schema, stale files, files that did not parse, tags nothing knows
function M.check_vaults()
  local ok, hollows = pcall(function() return require('fey.hollow.court').hollows() end)
  local vaults = {}
  if ok then
    for _, hollow in ipairs(hollows) do
      vaults[#vaults + 1] = { id = hollow.id, vault = hollow.vault }
    end
  end
  -- the vaults that are open and are not in the court (a hollow that was opened by hand)
  local seen = {}
  for _, entry in ipairs(vaults) do
    seen[entry.vault.root] = true
  end
  local open = vim.tbl_values(require('fey.vault').all())
  table.sort(open, function(a, b) return a.root < b.root end)
  for _, vault in ipairs(open) do
    if not seen[vault.root] then vaults[#vaults + 1] = { id = vim.fn.fnamemodify(vault.root, ':~'), vault = vault } end
  end
  local current = require('fey.vault').current()
  if #vaults == 0 and current then vaults[1] = { id = current.root, vault = current } end
  if #vaults == 0 then return h.info('no hollow is open: nothing to say about the index') end

  local known = known_tag_names()
  for _, entry in ipairs(vaults) do
    local vault = entry.vault
    local s = vault:status()
    local label = ('hollow `%s`'):format(entry.id)
    if vault.state == 'error' or s.last_error then
      h.error(('%s: the index failed: %s'):format(label, tostring(s.last_error)))
    else
      h.ok(('%s: %d files indexed, state %s, schema %s'):format(label, s.files, s.state or 'unknown', tostring(s.db_schema)))
    end
    if s.db_schema ~= nil and s.db_schema ~= s.schema then
      h.warn(('%s: the index has schema %d, this version of the plugin writes %d (it is rebuilt at the next scan)'):format(label, s.db_schema, s.schema))
    end
    local stale = vim.list_extend(vim.list_extend(vim.list_extend({}, s.changed), s.new), s.removed)
    if #stale > 0 then
      local lines = {}
      for _, p in ipairs(s.changed) do lines[#lines + 1] = 'changed: ' .. p end
      for _, p in ipairs(s.new) do lines[#lines + 1] = 'not indexed: ' .. p end
      for _, p in ipairs(s.removed) do lines[#lines + 1] = 'gone: ' .. p end
      h.warn(('%s: the index is stale for %d file%s, the next scan fixes it'):format(label, #stale, #stale == 1 and '' or 's'), lines)
    else
      h.ok(label .. ': the index is up to date')
    end
    if #s.errors > 0 then
      h.warn(
        ('%s: %d file%s did not parse cleanly'):format(label, #s.errors, #s.errors == 1 and '' or 's'),
        vim.tbl_map(function(e) return ('%s (%d)'):format(e.path, e.count) end, s.errors)
      )
    end
    local unknown = {}
    for _, row in ipairs(vault:query('SELECT name, COUNT(*) AS n FROM tags GROUP BY name ORDER BY n DESC, name')) do
      if not known[row.name] then unknown[#unknown + 1] = ('%s (%d)'):format(row.name, row.n) end
    end
    if #unknown > 0 then
      h.info(
        ('%s: tags nothing in the setup knows (fine for data, a typo if you meant a tag of the plugin)'):format(label),
        unknown
      )
    end
  end
end

function M.check_has_treesitter()
  local ts = require('fey.utils.treesitter.install')
  local version_info = ts.get_version_info()
  if not version_info.installed then
    return h.error('Treesitter grammar is not installed. Run `:Fey install_treesitter_grammar` to install it.')
  end

  if #version_info.parser_locations > 1 then
    local list = vim.tbl_map(function(parser)
      return ('- `%s`'):format(parser)
    end, version_info.parser_locations)
    return h.warn(
      ('Multiple fey parsers found in these locations:\n%s\nDelete unused ones to avoid conflicts.'):format(
        table.concat(list, '\n')
      )
    )
  end

  if not version_info.installed_in_fey_dir then
    return h.ok(
      ('Tree-sitter grammar is installed, but not by fey.nvim plugin. Any issues or version mismatch will need to be handled manually.\nIf you want fey.nvim to manage the parser installation (recommended), remove the installed parser at "%s" and restart Neovim.'):format(
        version_info.parser_locations[1]
      )
    )
  end

  if version_info.outdated then
    return h.error('Treesitter grammar is out of date. Run `:Fey install_treesitter_grammar` to update it.')
  end

  if version_info.version_mismatch then
    return h.warn(
      ('Treesitter grammar version mismatch (installed %s, required %s). Run `:Fey install_treesitter_grammar` to update it.'):format(
        version_info.installed_version,
        version_info.required_version
      )
    )
  end

  return h.ok(('Treesitter grammar installed (version %s)'):format(version_info.installed_version))
end

function M.check_setup()
  local config = require('fey.config')
  local fey = require('fey')

  if not fey.is_setup_called() then
    h.warn('Setup not called')
  else
    h.ok('Setup called')
  end

  if config.fey_agenda_files and #config.fey_agenda_files > 0 then
    h.info('`fey_agenda_files` is not used by the agenda any more: it reads the hollows of `fey_agenda_scope`')
  end
  if not config.fey_default_notes_file or config.fey_default_notes_file == '' then
    h.info('No default notes file configured: captures go to `agenda/inbox.fey` of the court')
  else
    h.ok('`fey_default_notes_file` configured')
  end

  -- footnotes that are referenced and have no definition, in the hollows that can be seen
  local ok, hollows = pcall(function() return require('fey.hollow.court').hollows() end)
  local missing = {}
  if ok then
    for _, hollow in ipairs(hollows) do
      for _, row in ipairs(hollow.vault:footnotes({ missing = true })) do
        missing[#missing + 1] = ('%s/%s: footnote %s (line %d)'):format(hollow.id, row.path, row.label, row.line or 0)
      end
    end
  end
  if #missing == 0 then
    h.ok('every footnote has a definition')
  else
    h.warn(('%d footnote%s without a definition'):format(#missing, #missing == 1 and '' or 's'), missing)
  end
end

function M.check_shellslash()
  if vim.fn.has('win32') ~= 1 then
    return
  end
  if not vim.opt.shellslash:get() then
    h.warn(
      '`shellslash` is not set. This might cause issues with file paths in links. Set `vim.opt.shellslash = true` in your configuration.'
    )
  else
    h.ok('`shellslash` is set')
  end
end

return M
