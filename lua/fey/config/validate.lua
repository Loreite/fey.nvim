-- The check of the options a user gave: a name that is not an option (a typo, or an option of a feature that is gone), a value of the
-- wrong type, a value that is not one of the choices. Run by `setup` (a warning, nothing is refused) and by `:checkhealth fey`.
local M = {}

---Options that were removed, with what to do instead
M.REMOVED = {
  fey_use_cwd_config = 'configuration comes from the court, the hollows and the note, see the `nvim` and `plugin` tags',
  fey_use_buffer_config = 'configuration comes from the court, the hollows and the note, see the `nvim` and `plugin` tags',
  fey_agenda_text_search_extra_files = 'the agenda reads the index of the hollows; there are no extra files to search',
  fey_tags_column = 'labels are a tag (`{# labels, a, b #}`) and are not aligned to a column',
  fey_reindex_fey_src_blocks = 'nothing to reindex: source blocks are not renumbered',
  emacs_config = 'the exporters of Emacs are gone; Markdown and HTML are written by Lua, the rest by pandoc, see `fey.export`',
  hyperlinks = 'links are tags; use `fey_link_schemes` for links of your own',
}

---The choices of the options that have a few
M.ENUMS = {
  fey_drawer_form = { 'pair', 'block' },
  fey_checkbox_icons = { 'auto', 'nerd', 'unicode' },
  fey_startup_folded = { 'overview', 'content', 'showeverything', 'inherit' },
  fey_footnote_definition_form = { 'pair', 'block', 'line' },
}

-- options that take more than one type, the check of the type leaves them alone
local UNION = {
  fey_agenda_start_on_weekday = true, fey_agenda_files = true, fey_agenda_scope = true, fey_refile_scope = true,
  fey_todo_keywords = true, fey_default_notes_file = true, fey_archive_location = true, fey_id_prefix = true,
  fey_agenda_start_day = true, fey_startup_folded = true, fey_footnote_superscript = true, fey_conceal_task_tags = true,
}

local known

---Every name of an option the plugin documents (the fields of `_meta.lua`), for the ones that have no default value to be found by
---@return table<string, boolean>
local function known_names()
  if known then return known end
  known = {}
  for _, path in ipairs(vim.api.nvim_get_runtime_file('lua/fey/config/_meta.lua', false)) do
    for line in io.lines(path) do
      local name = line:match('^%-%-%-@field ([%w_]+)%??%s')
      if name then known[name] = true end
    end
  end
  return known
end

---@param value any
---@return string
local function type_of(value) return value == vim.NIL and 'nil' or type(value) end

---The problems of a set of options
---@param opts table what the user gave
---@param defaults table what is there to be set
---@return { name: string, message: string }[]
function M.check(opts, defaults)
  local problems = {}
  local names = vim.tbl_keys(opts or {})
  table.sort(names)
  for _, name in ipairs(names) do
    local value = opts[name]
    if M.REMOVED[name] then
      problems[#problems + 1] = { name = name, message = ('`%s` is gone: %s'):format(name, M.REMOVED[name]) }
    elseif defaults[name] == nil and not known_names()[name] and not name:match('^_') then
      problems[#problems + 1] = { name = name, message = ('`%s` is not an option'):format(name) }
    else
      local default = defaults[name]
      local choices = M.ENUMS[name]
      if choices and not vim.tbl_contains(choices, value) then
        problems[#problems + 1] = {
          name = name,
          message = ('`%s` is %s, it has to be one of %s'):format(name, vim.inspect(value), table.concat(choices, ', ')),
        }
      elseif not UNION[name] and not choices and value ~= nil then
        local want
        if name:match('_tag_name$') then
          want = 'string'
        elseif type(default) == 'boolean' then
          want = 'boolean'
        end
        if want and type_of(value) ~= want then
          problems[#problems + 1] = { name = name, message = ('`%s` has to be a %s, not a %s'):format(name, want, type_of(value)) }
        end
      end
    end
  end
  return problems
end

return M
