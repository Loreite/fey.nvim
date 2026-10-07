-- The options of this plugin that a note may change while it is open (`{# plugin, fey; ... #}`). It is a list:
-- appearance and the behaviour of the agenda, refile and capture. Not in it, on purpose: where things live (the court
-- and the hollows, the vault, the agenda files), the mappings and anything that runs code. `settings.hot_options` in
-- the setup adds names.
local M = {}

M.LIST = {
  -- what the notes look like
  'fey_conceal_task_tags',
  'fey_show_checkbox_state_as_icons',
  'fey_checkbox_icons',
  'fey_checkbox_icon_overrides',
  'fey_footnote_superscript',
  'fey_footnote_definition_form',
  'fey_hide_emphasis_markers',
  'fey_startup_folded',
  'fey_cycle_separator_lines',
  -- todo keywords, priorities, dates
  'fey_todo_keywords',
  'fey_todo_keyword_faces',
  'fey_log_done',
  'fey_deadline_warning_days',
  'fey_time_stamp_rounding_minutes',
  -- the agenda
  'fey_agenda_span',
  'fey_agenda_start_on_weekday',
  'fey_agenda_start_day',
  'fey_agenda_scope',
  'fey_agenda_show_scope',
  'fey_agenda_show_hollow',
  'fey_agenda_skip_archived',
  'fey_agenda_skip_scheduled_if_done',
  'fey_agenda_skip_deadline_if_done',
  'fey_agenda_remove_tags',
  'fey_agenda_use_time_grid',
  'fey_agenda_time_grid',
  'fey_agenda_block_separator',
  'fey_agenda_hide_empty_blocks',
  'fey_agenda_sorting_strategy',
  'fey_agenda_show_future_repeats',
  -- refile, archive, capture
  'fey_refile_scope',
  'fey_refile_leave_link',
  'fey_archive_location',
  -- reminders
  'notifications',
}

---@param name string
---@return boolean
function M.allowed(name)
  if vim.tbl_contains(M.LIST, name) then return true end
  local extra = (require('fey.config').settings or {}).hot_options or {}
  return vim.tbl_contains(extra, name)
end

return M
