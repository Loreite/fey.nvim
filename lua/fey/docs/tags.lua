-- The reference of every tag the plugin has, one heading each, made from this table and from the configuration (the name a tag has now, which is
-- what `fey_*_tag_name` says). `tests/docs.lua` fails when a `*_tag_name` option of `config/defaults.lua` has no entry here. A task that adds a tag
-- adds its entry here and its row to the table of tags of the roadmap.
local generated = require('fey.docs.generated')

local M = {}

---@class FeyDocTag
---@field option? string the option that renames it
---@field name? string the name, when no option has it
---@field forms table<string, string> form -> what it means
---@field head string
---@field body string
---@field where string
---@field indexed string
---@field open string what open at point (`<prefix>o`) does
---@field related string
---@field example string[]

---@type FeyDocTag[]
M.TAGS = {
  {
    option = 'fey_date_tag_name',
    forms = { scope_tag = 'a date in the text, a title or a note', line_tag = 'a date with the words it belongs to' },
    head = 'the date, `2026-10-07 Wed` or with a time `2026-10-07 Wed 09:30`, or a range; the key `active: false` makes it inactive (it is not in the agenda)',
    body = 'none for the scope form',
    where = 'anywhere in the text',
    indexed = 'a date of the kind `date`, with its time, its range, its repeater and warning',
    open = 'opens the calendar to change it; `<S-UP>`, `<S-DOWN>`, `<C-a>` and `<C-x>` change the part under the cursor',
    related = '`fey_date_insert` `fey_date_insert_inactive` `fey_toggle_date_type`, `fey_date_rounding_minutes`',
    example = { 'The review is {@ date, 2026-10-07 Wed 09:30 @}.' },
  },
  {
    option = 'fey_scheduled_tag_name',
    forms = { scope_tag = 'when to start the task of the heading' },
    head = 'a date, as for the date tag',
    body = 'none',
    where = 'under a heading, with the other planning tags (right after the title)',
    indexed = 'a date of the kind `scheduled`, shown in the agenda on its day and after it while the task is open',
    open = 'opens the calendar',
    related = '`fey_schedule` (`<prefix>is`), `fey_agenda_skip_scheduled_if_done`',
    example = { '  I. {# status, TODO #} Write the report', '{# scheduled, 2026-10-07 Wed #}' },
  },
  {
    option = 'fey_deadline_tag_name',
    forms = { scope_tag = 'when the task of the heading is due' },
    head = 'a date; a warning (`-3d`) says how long before it is shown',
    body = 'none',
    where = 'under a heading, with the other planning tags',
    indexed = 'a date of the kind `deadline`; the agenda shows it ahead of time (`fey_deadline_warning_days`) and the overdue ones are painted',
    open = 'opens the calendar',
    related = '`fey_deadline` (`<prefix>id`), `fey_agenda_skip_deadline_if_done`, `fey_highlight_overdue`',
    example = { '{# deadline, 2026-10-09 Fri #}' },
  },
  {
    option = 'fey_closed_tag_name',
    forms = { scope_tag = 'when the task was finished' },
    head = 'a date and a time; it is written when a task is marked done (`fey_log_done`)',
    body = 'none',
    where = 'under a heading, with the other planning tags',
    indexed = 'a date of the kind `closed`',
    open = 'nothing',
    related = '`fey_log_done`',
    example = { '{# closed, 2026-10-07 Wed 10:15 #}' },
  },
  {
    option = 'fey_status_tag_name',
    forms = { scope_tag = 'the state of a heading as a task' },
    head = 'the keyword, then the priority: `TODO`, `A`; the key `priority: A` for a priority without a keyword',
    body = 'none',
    where = 'the first thing of the title of a heading',
    indexed = 'a task of the kind `heading`, with its state, whether it is done and its priority',
    open = 'cycles the state; `fey_todo_next_state` and `fey_todo_prev_state` do it from anywhere in the heading',
    related = '`fey_todo_keywords`, `fey_todo_keyword_faces`, `fey_priority_*`, `fey_conceal_task_tags` (shows the keyword and hides the rest)',
    example = { '  I. {# status, TODO, A #} Write the report' },
  },
  {
    option = 'fey_labels_tag_name',
    forms = { scope_tag = 'the labels of a heading or, above the first heading, of the file' },
    head = 'the labels, a value each; a label with slashes (`work/reports`) is nested',
    body = 'none',
    where = 'in the title of a heading, in its text, or above the first heading',
    indexed = 'labels, with where they were found (the title, the text or the document), inherited by the headings below when `fey_use_label_inheritance` is on',
    open = 'nothing',
    related = '`fey_set_labels_command` (`<prefix>sl`), the agenda views by label, `fey_labels_exclude_from_inheritance`',
    example = { '  I. Write the report {# labels, work, reports #}' },
  },
  {
    option = 'fey_property_tag_name',
    forms = { scope_tag = 'properties of a heading' },
    head = 'keys only: `effort: 2h`, `category: work`, `id: ...`',
    body = 'none',
    where = 'under a heading, in the metadata at the start of its text',
    indexed = 'the properties of the heading, which queries and the agenda read (`effort`, `category`, `id`)',
    open = 'nothing',
    related = '`fey_set_effort` (`<prefix>xe`), `fey_use_property_inheritance`',
    example = { '{# prop; effort: 2h; category: work #}' },
  },
  {
    option = 'fey_clock_tag_name',
    forms = { scope_tag = 'one period of work on a heading' },
    head = 'the start; the keys `end` and `dur` once it is stopped (a clock with no end is running)',
    body = 'none',
    where = 'in the logbook of a heading',
    indexed = 'a date of the kind `clock`, with its start and end',
    open = 'nothing; editing a start or an end writes the duration again',
    related = '`fey_clock_in` `fey_clock_out` `fey_clock_cancel` `fey_clock_goto`, the clock report of the agenda, the clock table',
    example = { '[ logbook #]', '{# clock, 2026-10-06 Tue 10:00; end: 2026-10-06 Tue 11:30; dur: 1:30 #}', '[# logbook ]' },
  },
  {
    option = 'fey_logbook_tag_name',
    forms = { pair_tag = 'a drawer: the lines between the opener and the closer', block_tag = 'the same, as an indented body' },
    head = 'none',
    body = 'clocks and notes: list items with an inactive date',
    where = 'in the text of a heading, under its metadata',
    indexed = 'the dates and the clocks inside it',
    open = 'folds',
    related = '`fey_log_into_logbook`, `fey_drawer_form` (the form a new one is written in), `fey_add_note` (`<prefix>na`)',
    example = { '[ logbook #]', '-  {@ date, 2026-10-06 Tue 16:00; active: false @}  Note taken: waiting', '[# logbook ]' },
  },
  {
    option = 'fey_footnote_tag_name',
    forms = {
      scope_tag = 'a reference to a footnote',
      pair_tag = 'the definition, as a pair',
      block_tag = 'the definition, as an indented body',
      line_tag = 'the definition, as a line',
    },
    head = 'the label of the footnote',
    body = 'the text of the footnote (a definition)',
    where = 'a reference in the text; a definition anywhere',
    indexed = 'the labels, with the references and the definitions, so a reference without a definition and a definition nobody uses are found',
    open = 'jumps between the reference and the definition',
    related = '`fey_insert_footnote`, `fey_footnote_superscript`, `fey_footnote_definition_form`',
    example = { 'A claim {@ fn, 1 @}.', '', '[ fn, 1 #]', 'The note.', '[# fn ]' },
  },
  {
    option = 'fey_link_tag_name',
    forms = {
      scope_tag = 'a link written out',
      line_tag = 'the words of the line are the link',
      block_tag = 'what is under it is the link (a paragraph, a list, a table)',
      pair_tag = 'the same, between an opener and a closer',
    },
    head = 'the target (a file, a url, `id:...`, a file of another hollow); the keys `desc`, `section` and `n`, and `conceal`',
    body = 'what the link is made of, in the line, block and pair forms',
    where = 'anywhere in the text',
    indexed = 'a link, with its target file and section, so backlinks, broken links and queries work',
    open = 'follows it; a link in the body of another link wins when the cursor is on it',
    related = '`fey_insert_link`, `fey_store_link`, `fey_check_links`, `fey_link_schemes`, `fey_link_conceal_default`',
    example = { 'See {@ link, notes/design.fey; desc: the design; section: II.A. @}.' },
  },
  {
    option = 'fey_section_tag_name',
    forms = { scope_tag = 'a link to a heading by its signature', block_tag = 'the body is the link', pair_tag = 'the body is the link', line_tag = 'the words are the link' },
    head = 'the signature, then the file and the number of the heading when several have the signature',
    body = 'what the link is made of, in the forms that have a body',
    where = 'anywhere in the text; the tags are kept up to date when headings are renumbered',
    indexed = 'a link of the kind `section`',
    open = 'goes to the heading',
    related = '`fey_link_conceal_default`',
    example = { 'see {@ section, II.A. @}' },
  },
  {
    option = 'fey_query_tag_name',
    forms = { scope_tag = 'the query is in the head', line_tag = 'the query is the text', block_tag = 'the query is the indented body', pair_tag = 'the query is between the opener and the closer' },
    head = 'for the scope form the query; the keys `scope` (`current`, `tree`, `court` or hollows) and `conceal`',
    body = 'the query, in the Dataview style language (`TABLE`, `LIST`, `TASK`)',
    where = 'anywhere in the text; the result is written after it',
    indexed = 'as a tag only',
    open = 'runs it (`<prefix>qq`; `<prefix>qa` runs every query of the file)',
    related = '`fey_query_conceal_default`, the result tag',
    example = { '[ query ]#', '   TABLE file.name, length(file.outlinks) AS "Links"', '   FROM #design', '   SORT file.mtime DESC' },
  },
  {
    option = 'fey_query_result_tag_name',
    forms = { pair_tag = 'the result of the query before it, rewritten every time it runs' },
    head = 'the key `conceal: true` when the query is concealed',
    body = 'a table or a list, with links to the files',
    where = 'right after its query',
    indexed = 'as a tag; the links in it are links',
    open = 'a link in it follows',
    related = '`fey_query_conceal_default`',
    example = { '[ query_result #]', '| File | Links |', '+======+=======+', '| {@ link, a.fey @} | 3 |', '[# query_result ]' },
  },
  {
    option = 'fey_db_tag_name',
    forms = { scope_tag = 'shows a database view as a table', block_tag = 'the database and view are in the body' },
    head = 'the number of rows; the keys `db`, `view` and `conceal`',
    body = 'the name of the database, and of the view after a `>`',
    where = 'anywhere in the text; the table is written after it',
    indexed = 'as a tag only',
    open = 'runs it',
    related = '`fey_query_conceal_default`, the database commands (`:FeyDb`)',
    example = { '{# feydb, 10; db: projects; view: Open #}' },
  },
  {
    option = 'fey_db_result_tag_name',
    forms = { pair_tag = 'the table of the database view before it' },
    head = 'the key `conceal: true` when the tag is concealed',
    body = 'a table of data, with no links to the files',
    where = 'right after its database tag',
    indexed = 'as a tag only',
    open = 'nothing',
    related = '`fey_query_conceal_default`',
    example = { '[ feydb_result #]', '| name | status |', '[# feydb_result ]' },
  },
  {
    option = 'fey_clocktable_tag_name',
    forms = { scope_tag = 'the time clocked, as a table', block_tag = 'the same, with the keys in the head' },
    head = 'the span (`thisweek`, `lastmonth`, `7d`, `2026-10`, `2026-10-01--2026-10-07`, `all`) or the key `span`; `by` (`heading`, `file`, `day`), `scope` and `conceal`',
    body = 'none',
    where = 'anywhere in the text; the table is written after it',
    indexed = 'as a tag only; the table is a query over the clocks of the index',
    open = 'runs it',
    related = '`fey_query_conceal_default`',
    example = { '{# clocktable; span: thisweek; by: file #}' },
  },
  {
    option = 'fey_clocktable_result_tag_name',
    forms = { pair_tag = 'the table of the clock table before it' },
    head = 'the key `conceal: true` when the tag is concealed',
    body = 'a table of the time clocked, with a total',
    where = 'right after its clock table tag',
    indexed = 'as a tag; the links in it are links',
    open = 'a link in it follows',
    related = '`fey_query_conceal_default`',
    example = { '[ clocktable_result #]', '| Heading | Time |', '[# clocktable_result ]' },
  },
  {
    option = 'fey_hl_tag_name',
    forms = { scope_tag = 'colours what the tag applies to', line_tag = 'colours the words', block_tag = 'colours the body', pair_tag = 'colours the body' },
    head = 'the keys `fg`, `bg`, `bold`, `italic`, `strike`, `underline`, `link` (a highlight group)',
    body = 'what is coloured, in the forms that have a body',
    where = 'anywhere in the text',
    indexed = 'as a tag only',
    open = 'nothing',
    related = '',
    example = { 'some {# hl; fg: red; bold: true #} words' },
  },
  {
    option = 'fey_nvim_config_tag_name',
    forms = { scope_tag = 'options of the editor', line_tag = 'the same', block_tag = 'the options are the body, a table', pair_tag = 'the same' },
    head = 'the options as keys: `wrap: false`, `number: true`',
    body = 'a table of options, one after the other',
    where = 'a note, a hollow (`.fey/config.fey`) or the court',
    indexed = 'as a tag only',
    open = 'applies it (`<prefix>?t`)',
    related = '`settings` in the setup, the `nvim` options table of the configuration page',
    example = { '{# nvim; wrap: false; conceallevel: 2 #}' },
  },
  {
    option = 'fey_plugin_tag_name',
    forms = { scope_tag = 'options of a plugin', line_tag = 'the same', block_tag = 'the options are the body, a table', pair_tag = 'the same' },
    head = 'the name of the plugin (`fey` for this one), then its options as keys',
    body = 'a table of options',
    where = 'a note, a hollow (`.fey/config.fey`) or the court',
    indexed = 'as a tag only',
    open = 'applies it (`<prefix>?t`)',
    related = '`settings.plugins`, `fey.settings.register`, the options table of the configuration page',
    example = { '{# plugin, fey; fey_highlight_overdue: false #}' },
  },
  {
    option = 'fey_comment_tag_name',
    forms = {
      scope_tag = 'comments what it applies to: its paragraph, the list when it is alone in a list item, the file above the first heading',
      line_tag = 'comments the words',
      block_tag = 'comments the body',
      pair_tag = 'comments the body',
    },
    head = 'a boolean: `true` keeps what it covers in the index, `false` leaves it out; the key `index` says the same',
    body = 'what is commented',
    where = 'anywhere in the text',
    indexed = 'the tag; what it comments is not indexed unless `fey_comment_index_default` or the tag says so',
    open = 'nothing; the body is dimmed, and an export leaves it out',
    related = '`fey_comment_index_default`, `commentstring` (`gc`)',
    example = { '#[ comment ] a note to myself #' },
  },
  {
    option = 'fey_math_tag_name',
    forms = { line_tag = 'inline math', block_tag = 'a display equation', pair_tag = 'a display equation' },
    head = 'none',
    body = 'LaTeX, highlighted with the latex parser when it is installed',
    where = 'anywhere in the text',
    indexed = 'as a tag only',
    open = 'nothing',
    related = 'the export turns it into math',
    example = { 'The mass #[ math ] E = mc^2 # is energy.' },
  },
  {
    name = 'table',
    forms = { scope_tag = 'a key of the data of the document', block_tag = 'data as an indented list of keys', pair_tag = 'the same' },
    head = 'keys: `title`, `category`, `todo`, `archive`, `header_args`, `labels`, `id`, `author`, and any of your own',
    body = 'keys as list items for the block and pair forms',
    where = 'above the first heading (the data of the file), or in a section under a heading with a `_` signature',
    indexed = 'the properties of the file; the title, the category and the todo keywords are read from them',
    open = 'nothing',
    related = '`array` and `value` are the other data tags',
    example = { '{# table; title: Design notes; category: work #}' },
  },
  {
    name = 'array',
    forms = { scope_tag = 'a list of values as data', block_tag = 'a list as an indented body', pair_tag = 'the same' },
    head = 'the values',
    body = 'list items',
    where = 'where data is allowed, as for `table`',
    indexed = 'as data of the document or of a section',
    open = 'nothing',
    related = '`table`, `value`',
    example = { '{# array, 1, 2, 3 #}' },
  },
  {
    name = 'value',
    forms = { scope_tag = 'one value as data', block_tag = 'a value as an indented body', pair_tag = 'the same' },
    head = 'the value',
    body = 'the text of the value',
    where = 'where data is allowed, as for `table`',
    indexed = 'as data of the document or of a section',
    open = 'nothing',
    related = '`table`, `array`',
    example = { '{# value, 5 #}' },
  },
}

---The name a tag has now
---@param tag FeyDocTag
---@return string
function M.name_of(tag)
  if tag.option then return require('fey.config')[tag.option] or require('fey.config.defaults')[tag.option] end
  return tag.name
end

local FORM_ORDER = { 'scope_tag', 'line_tag', 'block_tag', 'pair_tag' }
local FORM_NAME = { scope_tag = 'scope', line_tag = 'line', block_tag = 'block', pair_tag = 'pair' }

-- the groups of the reference, in the order of the page: a name and the tags (by option, or by name for the data tags)
M.GROUPS = {
  { 'Dates and tasks', { 'fey_date_tag_name', 'fey_scheduled_tag_name', 'fey_deadline_tag_name', 'fey_closed_tag_name', 'fey_status_tag_name', 'fey_labels_tag_name', 'fey_property_tag_name', 'fey_clock_tag_name', 'fey_logbook_tag_name' } },
  { 'Text', { 'fey_footnote_tag_name', 'fey_link_tag_name', 'fey_section_tag_name', 'fey_comment_tag_name', 'fey_math_tag_name' } },
  { 'Queries and databases', { 'fey_query_tag_name', 'fey_query_result_tag_name', 'fey_db_tag_name', 'fey_db_result_tag_name', 'fey_clocktable_tag_name', 'fey_clocktable_result_tag_name' } },
  { 'Appearance and settings', { 'fey_hl_tag_name', 'fey_nvim_config_tag_name', 'fey_plugin_tag_name' } },
  { 'Data', { 'table', 'array', 'value' } },
}

---@param key string
---@return FeyDocTag|nil
local function find(key)
  for _, tag in ipairs(M.TAGS) do
    if tag.option == key or tag.name == key then return tag end
  end
end

local ROMAN = { 'I', 'II', 'III', 'IV', 'V', 'VI', 'VII', 'VIII' }

---The sections of the reference: a heading for each group and one for each tag under it
---@return string[]
function M.render()
  local out = {}
  for g, group in ipairs(M.GROUPS) do
    out[#out + 1] = ('  %s. %s'):format(ROMAN[g], group[1])
    out[#out + 1] = ''
    for i, key in ipairs(group[2]) do
      local tag = assert(find(key), key)
      local name = M.name_of(tag)
      out[#out + 1] = ('  %s.%s. %s'):format(ROMAN[g], string.char(64 + i), name)
      out[#out + 1] = ''
      if tag.option then
        out[#out + 1] = generated.prose(('The name is `%s`; the option `%s` changes it.'):format(name, tag.option))
      else
        out[#out + 1] = generated.prose(('The name is `%s`.'):format(name))
      end
      out[#out + 1] = ''
      local forms = {}
      for _, form in ipairs(FORM_ORDER) do
        if tag.forms[form] then forms[#forms + 1] = ('%s: %s'):format(FORM_NAME[form], generated.prose(tag.forms[form])) end
      end
      out[#out + 1] = '-  Forms:  ' .. table.concat(forms, '; ') .. '.'
      out[#out + 1] = '-  Head:  ' .. generated.prose(tag.head) .. '.'
      out[#out + 1] = '-  Body:  ' .. generated.prose(tag.body) .. '.'
      out[#out + 1] = '-  Where:  ' .. generated.prose(tag.where) .. '.'
      out[#out + 1] = '-  The index:  ' .. generated.prose(tag.indexed) .. '.'
      out[#out + 1] = '-  Open at point:  ' .. generated.prose(tag.open) .. '.'
      if tag.related ~= '' then out[#out + 1] = '-  Related:  ' .. generated.prose(tag.related) .. '.' end
      out[#out + 1] = ''
      out[#out + 1] = '###  src fey'
      for _, line in ipairs(tag.example) do
        out[#out + 1] = line
      end
      out[#out + 1] = '###'
      out[#out + 1] = ''
    end
  end
  return out
end

---Every tag of `M.TAGS` is in a group (or the page leaves it out)
---@return string[] keys of the tags no group has
function M.ungrouped()
  local seen = {}
  for _, group in ipairs(M.GROUPS) do
    for _, key in ipairs(group[2]) do
      seen[key] = true
    end
  end
  local out = {}
  for _, tag in ipairs(M.TAGS) do
    if not seen[tag.option or tag.name] then out[#out + 1] = tag.option or tag.name end
  end
  return out
end

return M
