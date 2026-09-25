local m = require('fey.config.mappings.map_entry')

return {
  global = {
    --   fey_agenda = m.action('agenda.prompt', { opts = { buffer = false, desc = 'fey agenda' } }),
    --   fey_capture = m.action('capture.prompt', { opts = { buffer = false, desc = 'fey capture' } }),
  },
  agenda = {
    --   fey_agenda_later = m.action(
    --     'agenda.advance_span',
    --     { args = { 1 }, opts = { desc = 'fey next agenda span', help_desc = 'Go forward one span' } }
    --   ),
    --   fey_agenda_earlier = m.action(
    --     'agenda.advance_span',
    --     { args = { -1 }, opts = { desc = 'fey prev agenda span', help_desc = 'Go backward one span' } }
    --   ),
    --   fey_agenda_goto_today = m.action('agenda.reset', { opts = { desc = 'fey goto today', help_desc = "Go to today's span" } }),
    --   fey_agenda_day_view = m.action(
    --     'agenda.change_span',
    --     { args = { 'day' }, opts = { desc = 'fey day view', help_desc = 'Show day view' } }
    --   ),
    --   fey_agenda_week_view = m.action(
    --     'agenda.change_span',
    --     { args = { 'week' }, opts = { desc = 'fey week view', help_desc = 'Show week view' } }
    --   ),
    --   fey_agenda_month_view = m.action(
    --     'agenda.change_span',
    --     { args = { 'month' }, opts = { desc = 'fey month view', help_desc = 'Show month view' } }
    --   ),
    --   fey_agenda_year_view = m.action(
    --     'agenda.change_span',
    --     { args = { 'year' }, opts = { desc = 'fey year view', help_desc = 'Show year view' } }
    --   ),
    --   fey_agenda_quit = m.action('agenda.quit', { opts = { desc = 'fey close agenda', help_desc = 'Close agenda' } }),
    --   fey_agenda_switch_to = m.action(
    --     'agenda.switch_to_item',
    --     { opts = { desc = 'fey open agenda item (same buffer)', help_desc = 'Open in current window' } }
    --   ),
    --   fey_agenda_goto = m.action(
    --     'agenda.goto_item',
    --     { opts = { desc = 'fey open agenda item (split buffer)', help_desc = 'Open in another window' } }
    --   ),
    --   fey_agenda_goto_date = m.action(
    --     'agenda.goto_date',
    --     { opts = { desc = 'fey goto date', help_desc = 'Jump to specific date' } }
    --   ),
    --   fey_agenda_redo = m.action(
    --     'agenda.redo',
    --     { args = { 'mapping' }, opts = { desc = 'fey redo', help_desc = 'Reload fey files and redraw' } }
    --   ),
    --   fey_agenda_todo = m.action(
    --     'agenda.change_todo_state',
    --     { opts = { desc = 'fey cycle todo state', help_desc = 'Change TODO state of an item' } }
    --   ),
    --   fey_agenda_clock_in = m.action(
    --     'agenda.clock_in',
    --     { opts = { desc = 'fey clock in', help_desc = 'Clock in item under cursor' } }
    --   ),
    --   fey_agenda_clock_out = m.action(
    --     'agenda.clock_out',
    --     { opts = { desc = 'fey clock out', help_desc = 'Clock out currently active clocked item' } }
    --   ),
    --   fey_agenda_clock_cancel = m.action(
    --     'agenda.clock_cancel',
    --     { opts = { desc = 'fey clock cancel', help_desc = 'Cancel clocking on currently active clocked item' } }
    --   ),
    --   fey_agenda_set_effort = m.action(
    --     'agenda.set_effort',
    --     { opts = { desc = 'fey set effort', help_desc = 'Set effort estimate for item under cursor' } }
    --   ),
    --   fey_agenda_clock_goto = m.action(
    --     'clock.fey_clock_goto',
    --     { opts = { desc = 'fey goto active clock item', help_desc = 'Jump to currently active clock item' } }
    --   ),
    --   fey_agenda_clockreport_mode = m.action(
    --     'agenda.toggle_clock_report',
    --     { opts = { desc = 'fey clockreport mode', help_desc = 'Toggle clock report for current agenda time range' } }
    --   ),
    --   fey_agenda_priority = m.action(
    --     'agenda.set_priority',
    --     { opts = { desc = 'fey set priority', help_desc = 'Set priority for current item' } }
    --   ),
    --   fey_agenda_priority_up = m.action(
    --     'agenda.priority_up',
    --     { opts = { desc = 'fey increase priority', help_desc = 'Increase priority for current item' } }
    --   ),
    --   fey_agenda_priority_down = m.action(
    --     'agenda.priority_down',
    --     { opts = { desc = 'fey decrease priority', help_desc = 'Decrease priority for current item' } }
    --   ),
    --   fey_agenda_archive = m.action(
    --     'agenda.archive',
    --     { opts = { desc = 'fey archive subtree', help_desc = 'Archive heading to archive file' } }
    --   ),
    --   fey_agenda_toggle_archive_tag = m.action(
    --     'agenda.toggle_archive_tag',
    --     { opts = { desc = 'fey toggle archive tag', help_desc = 'Toggle "ARCHIVE" tag on current heading' } }
    --   ),
    --   fey_agenda_set_tags = m.action(
    --     'agenda.set_tags',
    --     { opts = { desc = 'fey set tags', help_desc = 'Change tags of current heading' } }
    --   ),
    --   fey_agenda_deadline = m.action(
    --     'agenda.set_deadline',
    --     { opts = { desc = 'fey deadline', help_desc = 'Insert/Update deadline date on current heading' } }
    --   ),
    --   fey_agenda_schedule = m.action(
    --     'agenda.set_schedule',
    --     { opts = { desc = 'fey schedule', help_desc = 'Insert/Update scheduled date on current heading' } }
    --   ),
    --   fey_agenda_filter = m.action('agenda.filter', {
    --     opts = {
    --       desc = 'fey filter',
    --       help_desc = 'Open prompt that allows filtering by category, tags and title(vim regex)',
    --     },
    --   }),
    --   fey_agenda_open_at_point = m.action(
    --     'agenda.open_at_point',
    --     { opts = { desc = 'fey open', help_desc = 'Open hyperlink under cursor' } }
    --   ),
    --   fey_agenda_refile = m.action('agenda.refile', {
    --     opts = {
    --       desc = 'fey refile',
    --       help_desc = 'Refile heading to specific destination',
    --     },
    --   }),
    --   fey_agenda_preview = m.action('agenda.preview_item', {
    --     opts = {
    --       desc = 'fey preview',
    --       help_desc = 'Preview agenda item in floating window',
    --     },
    --   }),
    --   fey_agenda_add_note = m.action(
    --     'agenda.add_note',
    --     { opts = { desc = 'fey add note', help_desc = 'Add a note to the current heading' } }
    --   ),
    --   fey_agenda_show_help = m.action(
    --     'fey_mappings.show_help',
    --     { args = { 'agenda' }, opts = { desc = 'fey show help', help_desc = 'Show this help' } }
    --   ),
  },
  capture = {
    --   fey_capture_finalize = m.action(
    --     'capture.refile',
    --     { opts = { desc = 'fey finalize', help_desc = 'Save to default notes file and close the window' } }
    --   ),
    --   fey_capture_refile = m.action(
    --     'capture.refile_to_destination',
    --     { opts = { desc = 'fey refile', help_desc = 'Save to specific destination' } }
    --   ),
    --   fey_capture_kill = m.action('capture.kill', { opts = { desc = 'fey kill', help_desc = 'Close without saving' } }),
    --   fey_capture_show_help = m.action(
    --     'fey_mappings.show_help',
    --     { args = { 'capture' }, opts = { desc = 'fey show help', help_desc = 'Show this help' } }
    --   ),
    -- },
    -- note = {
    --   fey_note_finalize = m.action(
    --     'capture.closing_note.finish',
    --     { opts = { desc = 'fey finalize note', help_desc = 'Save note and close the window' } }
    --   ),
    --   fey_note_kill = m.action(
    --     'capture.closing_note.kill',
    --     { opts = { desc = 'fey kill note', help_desc = 'Close without saving' } }
    --   ),
  },
  fey = {
    --   fey_refile = m.action(
    --     'capture.refile_heading_to_destination',
    --     { opts = { desc = 'fey refile', help_desc = 'Refile heading to specific destination' } }
    --   ),
    --   fey_timestamp_up_day = m.action(
    --     'fey_mappings.timestamp_up_day',
    --     { opts = { desc = 'fey increase timestamp (day)', help_desc = 'Increase timestamp by one day' } }
    --   ),
    --   fey_timestamp_down_day = m.action(
    --     'fey_mappings.timestamp_down_day',
    --     { opts = { desc = 'fey decrease timestamp (day)', help_desc = 'Decrease timestamp by one day' } }
    --   ),
    --   fey_timestamp_up = m.action('fey_mappings.timestamp_up', {
    --     opts = {
    --       desc = 'fey increase timestamp',
    --       help_desc = 'Increase date part under cursor (year/month/day/hour/minute/repeater/active|inactive)',
    --     },
    --   }),
    --   fey_timestamp_down = m.action('fey_mappings.timestamp_down', {
    --     opts = {
    --       desc = 'fey decrease timestamp',
    --       help_desc = 'Decrease date part under cursor (year/month/day/hour/minute/repeater/active|inactive)',
    --     },
    --   }),
    --   fey_change_date = m.action(
    --     'fey_mappings.change_date',
    --     { opts = { desc = 'fey change date', help_desc = 'Change date under cursor via calendar popup' } }
    --   ),
    --   fey_todo = m.action(
    --     'fey_mappings.todo_next_state',
    --     { opts = { desc = 'fey next todo state', help_desc = 'Forward change TODO state of current heading' } }
    --   ),
    --   fey_todo_prev = m.action(
    --     'fey_mappings.todo_prev_state',
    --     { opts = { desc = 'fey prev todo state', help_desc = 'Backward change TODO state of current heading' } }
    --   ),
    --   fey_priority = m.action(
    --     'fey_mappings.set_priority',
    --     { opts = { desc = 'fey cycle priority', help_desc = 'Change the priority of the current heading' } }
    --   ),
    --   fey_priority_up = m.action(
    --     'fey_mappings.priority_up',
    --     { opts = { desc = 'fey increase priority', help_desc = 'Increase priority of heading' } }
    --   ),
    --   fey_priority_down = m.action(
    --     'fey_mappings.priority_down',
    --     { opts = { desc = 'fey decrease priority', help_desc = 'Decrease priority of heading' } }
    --   ),
    --   fey_toggle_checkbox = m.action(
    --     'fey_mappings.toggle_checkbox',
    --     { opts = { desc = 'fey toggle checkbox', help_desc = 'Toggle checkbox' } }
    --   ),
    --   fey_toggle_heading = m.action(
    --     'fey_mappings.toggle_heading',
    --     { opts = { desc = 'fey toggle heading', help_desc = 'Toggle current line to heading and vice versa' } }
    --   ),
    --   fey_open_at_point = m.action(
    --     'fey_mappings.open_at_point',
    --     { opts = { desc = 'fey open', help_desc = 'Open hyperlink or date under cursor' } }
    --   ),
    --   fey_edit_special = m.action(
    --     'fey_mappings.edit_special',
    --     { opts = { desc = 'fey edit special', help_desc = 'Edit the source block under the cursor in another buffer' } }
    --   ),
    --   fey_add_note = m.action(
    --     'fey_mappings.add_note',
    --     { opts = { desc = 'fey add note', help_desc = 'Add a note to the current heading' } }
    --   ),
    --   fey_cycle = m.action('fey_mappings.cycle', { opts = { desc = 'fey toggle fold', help_desc = 'Toggle folding' } }),
    --   fey_global_cycle = m.action(
    --     'fey_mappings.global_cycle',
    --     { opts = { desc = 'fey toggle fold (whole file)', help_desc = 'Toggle folding (whole file)' } }
    --   ),
    --   fey_archive_subtree = m.action(
    --     'fey_mappings.archive',
    --     { opts = { desc = 'fey archive subtree', help_desc = 'Archive subtree to archive file' } }
    --   ),
    --   fey_set_tags_command = m.action(
    --     'fey_mappings.set_tags',
    --     { opts = { desc = 'fey set tags', help_desc = 'Change tags of current heading' } }
    --   ),
    --   fey_toggle_archive_tag = m.action(
    --     'fey_mappings.toggle_archive_tag',
    --     { opts = { desc = 'fey toggle archive tag', help_desc = 'Toggle "ARCHIVE" tag on current heading' } }
    --   ),

    -- BEGIN: First Mappings
    fey_anonymize_heading = m.action('fey_mappings.anonymize_or_enumerate_full_heading', {
      args = { false },
      opts = { desc = 'anonymize full heading signature', help_desc = 'make all segments of signature anonymous' },
    }),
    fey_enumerate_heading = m.action('fey_mappings.anonymize_or_enumerate_full_heading', {
      args = { true },
      opts = { desc = 'enumerate full heading signature', help_desc = 'make all segments of signature enumerated' },
    }),

    fey_change_all_delimiters_from_end = m.action('fey_mappings.change_all_delimiters', {
      args = { false },
      opts = { desc = 'change all heading delimiters from end', help_desc = 'update all delimiters to prompted value from end' },
    }),
    fey_change_all_delimiters_from_start = m.action('fey_mappings.change_all_delimiters', {
      args = { true },
      opts = {
        desc = 'change all heading delimiters from start',
        help_desc = 'update all delimiters to prompted value from start',
      },
    }),
    fey_anonymize_heading_from_end = m.action('fey_mappings.anonymize_or_enumerate_heading', {
      args = { false, false },
      opts = {
        desc = 'anonymize heading signature from end',
        help_desc = 'make {count} segments of signature from end anonymous',
      },
    }),
    fey_enumerate_heading_from_end = m.action('fey_mappings.anonymize_or_enumerate_heading', {
      args = { true, false },
      opts = {
        desc = 'enumerate heading signature from end',
        help_desc = 'make {count} segments of signature from end indexed',
      },
    }),
    fey_anonymize_heading_from_start = m.action('fey_mappings.anonymize_or_enumerate_heading', {
      args = { false, true },
      opts = {
        desc = 'anonymize heading signature from start',
        help_desc = 'make {count} segments of signature from start anonymous',
      },
    }),
    fey_enumerate_heading_from_start = m.action('fey_mappings.anonymize_or_enumerate_heading', {
      args = { true, true },
      opts = {
        desc = 'enumerate heading signature from start',
        help_desc = 'make {count} segments of signature from start indexed',
      },
    }),
    fey_reindex_headings_or_list = m.action(
      'fey_mappings.reindex_heading_or_list',
      { opts = { desc = 'reindex heading or list', help_desc = 'triggers and automatic reindex of a list or headings' } }
    ),
    fey_fix_indentation = m.action(
      'fey_mappings.fix_indentation',
      { opts = { desc = 'fix indentation', help_desc = 'Assert indentation for subsection' } }
    ),
    fey_do_promote = m.action(
      'fey_mappings.do_promote',
      { opts = { desc = 'promote heading', help_desc = 'Promote heading' } }
    ),
    fey_do_demote = m.action('fey_mappings.do_demote', { opts = { desc = 'demote heading', help_desc = 'Demote heading' } }),
    fey_promote_subtree = m.action(
      'fey_mappings.do_promote',
      { args = { true }, opts = { desc = 'promote subtree', help_desc = 'Promote whole subtree' } }
    ),
    fey_demote_subtree = m.action(
      'fey_mappings.do_demote',
      { args = { true }, opts = { desc = 'demote subtree', help_desc = 'Demote whole subtree' } }
    ),
    fey_move_subtree_up = m.action(
      'fey_mappings.move_subtree_up',
      { opts = { desc = 'move subtree up', help_desc = 'Move subtree up' } }
    ),
    fey_move_subtree_down = m.action(
      'fey_mappings.move_subtree_down',
      { opts = { desc = 'move subtree down', help_desc = 'Move subtree down' } }
    ),
    fey_meta_return = m.action(
      'fey_mappings.meta_return',
      { opts = { desc = 'meta return', help_desc = 'Add heading at {count} level, list item or checkbox (context aware)' } }
    ),
    fey_meta_sub_return = m.action('fey_mappings.meta_return', {
      args = { '', true },
      opts = {
        desc = 'meta sub-return',
        help_desc = 'Add subheading at curr+{1 or count} level, list item or checkbox (context aware)',
      },
    }),
    fey_insert_heading_respect_content = m.action('fey_mappings.insert_heading_respect_content', {
      opts = { desc = 'insert heading (respect content)', help_desc = 'Add new heading after current subtree' },
    }),
    fey_insert_subheading_respect_content = m.action('fey_mappings.insert_heading_respect_content', {
      args = { '', true },
      opts = { desc = 'insert subheading (respect content)', help_desc = 'Add new subheading after current subtree' },
    }),
    -- END:

    -- BEGIN: Table Mappings
    fey_table_reformat = m.action(
      'fey_mappings.table_reformat',
      { opts = { desc = 'reformat table', help_desc = 'reformat table, reflowing text and aligning to a grid' } }
    ),
    fey_table_insert_row_before = m.action('fey_mappings.table_insert_row', {
      args = { 'before' },
      opts = { desc = 'insert row before', help_desc = 'insert a blank row before the current row under cursor' },
    }),
    fey_table_insert_row_after = m.action('fey_mappings.table_insert_row', {
      args = { 'after' },
      opts = { desc = 'insert row after', help_desc = 'insert a blank row after the current row under cursor' },
    }),
    fey_table_delete_row = m.action(
      'fey_mappings.table_delete',
      { args = { 'row' }, opts = { desc = 'delete row', help_desc = 'delete the current row under curosr' } }
    ),
    fey_table_move_row_up = m.action(
      'fey_mappings.table_move_row',
      { args = { 'up' }, opts = { desc = 'move row up', help_desc = 'move the current table row under cursor up' } }
    ),
    fey_table_move_row_down = m.action(
      'fey_mappings.table_move_row',
      { args = { 'down' }, opts = { desc = 'move row down', help_desc = 'move the current table row under cursor down' } }
    ),
    --
    fey_table_insert_col_before = m.action('fey_mappings.table_insert_col', {
      args = { 'before' },
      opts = { desc = 'insert col before', help_desc = 'insert a blank col befre the current col under curosr' },
    }),
    fey_table_insert_col_after = m.action('fey_mappings.table_insert_col', {
      args = { 'after' },
      opts = { desc = 'insert col after', help_desc = 'insert a blank col after the current col under cursor' },
    }),
    fey_table_delete_col = m.action(
      'fey_mappings.table_delete',
      { args = { 'col' }, opts = { desc = 'delete col', help_desc = 'delete the current col under cursor' } }
    ),
    fey_table_move_col_left = m.action(
      'fey_mappings.table_move_col',
      { args = { 'left' }, opts = { desc = 'move col left', help_desc = 'move the current table col under curosr left' } }
    ),
    fey_table_move_col_right = m.action(
      'fey_mappings.',
      { args = { 'right' }, opts = { desc = 'move col right', help_desc = 'move the current table col under curosr right' } }
    ),
    --
    fey_table_move_cell_up = m.action(
      'fey_mappings.table_move_cell',
      { args = { 'up' }, opts = { desc = 'move cell up', help_desc = 'swap current cell under curosr with cell above' } }
    ),
    fey_table_move_cell_down = m.action(
      'fey_mappings.table_move_cell',
      { args = { 'down' }, opts = { desc = 'move cell down', help_desc = 'swap current cell under cursor with cell below' } }
    ),
    fey_table_move_cell_left = m.action('fey_mappings.table_move_cell', {
      args = { 'left' },
      opts = { desc = 'move cell left', help_desc = 'swap current cell under cursor with cell to the left' },
    }),
    fey_table_move_cell_right = m.action('fey_mappings.table_move_cell', {
      args = { 'right' },
      opts = { desc = 'move cell right', help_desc = 'swap current cell under cursor with cell to the right' },
    }),
    --
    fey_table_merge_cell_down = m.action('fey_mappings.table_merge_cell', {
      args = { 'down' },
      opts = { desc = 'merge cell down', help_desc = 'combine current cell under cursor with cell below' },
    }),
    fey_table_merge_cell_right = m.action('fey_mappings.table_merge_cell', {
      args = { 'right' },
      opts = { desc = 'merge cell right', help_desc = 'combine current cell under cursor with cell to the right' },
    }),
    fey_table_unmerge_cells = m.action('fey_mappings.table_merge_cell', {
      args = { 'unmerge' },
      opts = { desc = 'unmerge cells', help_desc = 'break apart combined cells into individual cells' },
    }),

    -- END:

    --   fey_insert_todo_heading = m.action(
    --     'fey_mappings.insert_todo_heading',
    --     { opts = { desc = 'fey insert todo', help_desc = 'Add new TODO heading on line right after current line' } }
    --   ),
    --   fey_insert_todo_heading_respect_content = m.action('fey_mappings.insert_todo_heading_respect_content', {
    --     opts = { desc = 'fey insert todo (respect content)', help_desc = 'Add new TODO heading after current subtree' },
    --   }),
    --   fey_export = m.action('fey_mappings.export', { opts = { desc = 'fey export', help_desc = 'Open export options' } }),
    --   fey_return = m.action('fey_mappings.fey_return', { modes = { 'i' }, opts = { desc = 'fey return' } }),
    --   fey_next_visible_heading = m.action('fey_mappings.next_visible_heading', {
    --     modes = { 'n', 'x' },
    --     opts = { desc = 'fey next visible heading', help_desc = 'Go to next heading (any level)' },
    --   }),
    --   fey_previous_visible_heading = m.action('fey_mappings.previous_visible_heading', {
    --     modes = { 'n', 'x' },
    --     opts = { desc = 'fey prev visible heading', help_desc = 'Go to previous heading (any level)' },
    --   }),
    --   fey_forward_heading_same_level = m.action(
    --     'fey_mappings.forward_heading_same_level',
    --     { opts = { desc = 'fey next heading (same level)', help_desc = 'Go to next heading at the same level' } }
    --   ),
    --   fey_backward_heading_same_level = m.action(
    --     'fey_mappings.backward_heading_same_level',
    --     { opts = { desc = 'fey prev heading (same level)', help_desc = 'Go to previous heading at the same level' } }
    --   ),
    --   outline_up_heading = m.action(
    --     'fey_mappings.outline_up_heading',
    --     { opts = { desc = 'fey goto parent heading', help_desc = 'Go to parent heading' } }
    --   ),
    --   fey_deadline = m.action(
    --     'fey_mappings.fey_deadline',
    --     { opts = { desc = 'fey deadline', help_desc = 'Insert/Update deadline date' } }
    --   ),
    --   fey_schedule = m.action(
    --     'fey_mappings.fey_schedule',
    --     { opts = { desc = 'fey schedule', help_desc = 'Insert/Update scheduled date' } }
    --   ),
    --   fey_time_stamp = m.action(
    --     'fey_mappings.fey_time_stamp',
    --     { opts = { desc = 'fey timestamp', help_desc = 'Insert date under cursor' } }
    --   ),
    --   fey_time_stamp_inactive = m.action('fey_mappings.fey_time_stamp', {
    --     args = { true },
    --     opts = { desc = 'fey timestamp (inactive)', help_desc = 'Insert/Update inactive date under cursor' },
    --   }),
    --   fey_insert_link = m.action('fey_mappings.insert_link', {
    --     modes = { 'n', 'x' },
    --     opts = {
    --       desc = 'fey insert link',
    --       help_desc = 'Insert or Update a hyperlink under cursor. Visual selection used as description',
    --     },
    --   }),
    --   fey_store_link = m.action(
    --     'fey_mappings.store_link',
    --     { opts = { desc = 'fey store link', help_desc = 'Store link to current heading' } }
    --   ),
    --   fey_clock_in = m.action('clock.fey_clock_in', { opts = { desc = 'fey clock in', help_desc = 'Clock in current heading' } }),
    --   fey_clock_out = m.action(
    --     'clock.fey_clock_out',
    --     { opts = { desc = 'fey clock out', help_desc = 'Clock out current heading' } }
    --   ),
    --   fey_clock_cancel = m.action(
    --     'clock.fey_clock_cancel',
    --     { opts = { desc = 'fey clock cancel', help_desc = 'Cancel active clock on current heading' } }
    --   ),
    --   fey_clock_goto = m.action(
    --     'clock.fey_clock_goto',
    --     { opts = { desc = 'fey clock goto', help_desc = 'Jump to currently clocked in heading' } }
    --   ),
    --   fey_set_effort = m.action(
    --     'clock.fey_set_effort',
    --     { opts = { desc = 'fey set effort', help_desc = 'Set effort estimate on current heading' } }
    --   ),
    --   fey_show_help = m.action('fey_mappings.show_help', {
    --     args = { 'fey' },
    --     opts = { desc = 'fey show help', help_desc = 'Show this help' },
    --   }),
    --   fey_babel_tangle = m.action(
    --     'fey_mappings.fey_babel_tangle',
    --     { opts = { desc = 'fey tangle', help_desc = 'Tangle current file' } }
    --   ),
    --   fey_toggle_timestamp_type = m.action(
    --     'fey_mappings.fey_toggle_timestamp_type',
    --     { opts = { desc = 'fey toggle timestamp type', help_desc = 'Toggle timestamp active/inactive type' } }
    --   ),
  },
  edit_src = {
    --   fey_edit_src_abort = m.custom(
    --     [[<Cmd>lua require('fey.objects.edit_special').abort()<CR>]],
    --     { opts = { desc = 'fey abort', help_desc = 'Abort edit special buffer changes and discard content' } }
    --   ),
    --   fey_edit_src_show_help = m.custom(
    --     [[<Cmd>lua require('fey.objects.help').show('edit_src')<CR>]],
    --     { opts = { desc = 'fey show help', help_desc = 'Show this help' } }
    --   ),
    --   fey_edit_src_save = m.custom(
    --     [[<Cmd>lua require('fey.objects.edit_special'):new():write()<CR>]],
    --     { opts = { desc = 'fey save', help_desc = 'Apply changes from the special buffer to the source Fey buffer' } }
    --   ),
    --   fey_edit_src_save_exit = m.custom([[<Cmd>lua require('fey.objects.edit_special'):new():write_end_exit()<CR>]], {
    --     opts = {
    --       desc = 'fey save and exit',
    --       help_desc = 'Apply changes from the special buffer to the source Fey buffer and exit',
    --     },
    --   }),
  },
  text_objects = {
    inner_heading = m.text_object('inner_heading', { help_desc = 'Select inner heading' }),
    around_heading = m.text_object('around_heading', { help_desc = 'Select around heading' }),
    inner_subtree = m.text_object('inner_subtree', { help_desc = 'Select inner subtree' }),
    around_subtree = m.text_object('around_subtree', { help_desc = 'Select around subtree' }),
    inner_heading_from_root = m.text_object(
      'inner_heading_from_root',
      { help_desc = 'Select inner heading from root heading' }
    ),
    around_heading_from_root = m.text_object(
      'around_heading_from_root',
      { help_desc = 'Select around heading from root heading' }
    ),
    inner_subtree_from_root = m.text_object(
      'inner_subtree_from_root',
      { help_desc = 'Select inner subtree from root heading' }
    ),
    around_subtree_from_root = m.text_object(
      'around_subtree_from_root',
      { help_desc = 'Select around subtree from root heading' }
    ),
  },
}
