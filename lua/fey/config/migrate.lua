-- The old names of options and mappings, moved to the new ones (III.R: the words of orgmode that mean something else in Fey). `setup` moves
-- what it is given and says so once per name; a note's `plugin` tag may use the old option names too, and `:checkhealth fey` lists the old names
-- that are still in use. The old names are kept for a release.
local M = {}

---@type table<string, string> options: old name -> new name
M.OPTIONS = {
  fey_use_tag_inheritance = 'fey_use_label_inheritance',
  fey_tags_exclude_from_inheritance = 'fey_labels_exclude_from_inheritance',
  fey_agenda_remove_tags = 'fey_agenda_remove_labels',
  fey_time_stamp_rounding_minutes = 'fey_date_rounding_minutes',
}

---@type table<string, string> mappings (in any group of `mappings`): old name -> new name
M.MAPPINGS = {
  fey_set_tags_command = 'fey_set_labels_command',
  fey_agenda_set_tags = 'fey_agenda_set_labels',
  fey_timestamp_up_day = 'fey_date_up_day',
  fey_timestamp_down_day = 'fey_date_down_day',
  fey_timestamp_up = 'fey_date_up',
  fey_timestamp_down = 'fey_date_down',
  fey_time_stamp = 'fey_date_insert',
  fey_time_stamp_inactive = 'fey_date_insert_inactive',
  fey_toggle_timestamp_type = 'fey_toggle_date_type',
}

---Only the option names of a table, the old ones renamed (a note's `plugin` tag)
---@param opts table
---@return table
function M.options(opts)
  local out = {}
  for key, value in pairs(opts) do
    out[M.OPTIONS[key] or key] = value
  end
  return out
end

---Move the old names of options and mappings to the new ones
---@param opts table what the user gave
---@return table opts the same with the new names (the old table is not changed)
---@return string[] notes what was moved, to say once
function M.apply(opts)
  local notes = {}
  local out = vim.deepcopy(opts or {})
  local function move(tbl, map, kind, where)
    for old, new in pairs(map) do
      if tbl[old] ~= nil then
        if tbl[new] == nil then tbl[new] = tbl[old] end
        tbl[old] = nil
        notes[#notes + 1] = ('the %s `%s%s` is now `%s`'):format(kind, where, old, new)
      end
    end
  end
  move(out, M.OPTIONS, 'option', '')
  if type(out.mappings) == 'table' then
    for group, mappings in pairs(out.mappings) do
      if type(mappings) == 'table' then move(mappings, M.MAPPINGS, 'mapping', 'mappings.' .. group .. '.') end
    end
  end
  table.sort(notes)
  return out, notes
end

---The old names a table of options still uses, for the health check
---@param opts table
---@return string[]
function M.find(opts)
  local _, notes = M.apply(opts)
  return notes
end

return M
