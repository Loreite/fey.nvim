-- The inventory and the check of the old words (III.R): the words of orgmode that mean something else in Fey, or nothing.
--
--   nvim --headless --clean -l scripts/terms.lua            the inventory: every word, the files it is in, how many times
--   nvim --headless --clean -l scripts/terms.lua --check    fail when a file uses an old word more often than the baseline says
--   nvim --headless --clean -l scripts/terms.lua --update   write the baseline (after a rename, so the count only goes down)
--
-- The check is a ratchet: the baseline (`scripts/terms_baseline.json`) is what is there today, a new use of an old word fails, a rename
-- that removes uses passes and `--update` makes the new, lower numbers the rule. The glossary (what to say instead) is in
-- `legal/contributing.fey` and in the roadmap (III.R). Not scanned: the credits and the history (`legal/`, `docs/`, `doc/`), the changelog,
-- this file, the tests (they name the old words to check that they are gone), the roadmap and the README.
local root = vim.fn.getcwd()

---@class FeyTerm
---@field name string the old word
---@field say string what to say
---@field patterns string[] Lua patterns, matched against each line of code

---@type FeyTerm[]
local TERMS = {
  { name = 'headline', say = 'heading', patterns = { '[Hh]eadline' } },
  {
    name = 'tags of a heading',
    say = 'labels',
    patterns = {
      'get_tags',
      'set_tags',
      'add_tag%f[%W]',
      'tags_to_string',
      'align_tags',
      'get_own_tags',
      'has_tag%f[%W]',
      'fey_use_tag_inheritance',
      'fey_tags_exclude_from_inheritance',
      'fey_agenda_remove_tags',
      'fey_set_tags',
    },
  },
  { name = 'stars', say = 'signature', patterns = { '%f[%w]stars%f[%W]' } },
  {
    name = 'timestamp',
    say = 'date',
    patterns = { 'time_stamp', 'timestamp_up', 'timestamp_down', 'timestamp_type', '[Tt]ime stamp' },
  },
  {
    name = 'plan',
    say = 'planning tags',
    patterns = { '%f[%w_]get_plan_', '%f[%w_]get_non_plan_', '_plan_dates', '%f[%w_]plan_dates', 'FeyPlanDateTypes' },
  },
  { name = 'drawer option', say = 'logbook (a pair or block tag)', patterns = { 'fey_log_into_drawer' } },
  {
    name = 'directive',
    say = 'key of the document data',
    patterns = { 'todo_directives', 'directive_name', 'org directive', 'get_directive', '_get_directive' },
  },
  {
    name = 'agenda files',
    say = 'the vault (the hollows); the deprecated option `fey_agenda_files` is not counted',
    patterns = { '%f[%w_]agenda_files' },
  },
  { name = 'src block, babel', say = 'fenced block named src', patterns = { 'src_block', 'end_src' } },
  { name = 'outline path', say = 'path of a heading', patterns = { 'outline_path' } },
  { name = 'org', say = 'fey', patterns = { '%f[%w]org%f[%W]', '[Oo]rgmode', '%.org%f[%W]' } },
}

-- lines that are the old name on purpose: the aliases that keep it working
local IGNORE_LINE =
  { 'alias%(', 'vim%.deprecate', '^utils%.tags_to_string = ', 'is the old name of the key', 'agenda_files` before' }

-- where the code is, and what is left out of the check
local DIRS = { 'lua', 'ftplugin', 'plugin', 'queries', 'syntax', 'indent', 'scripts', 'after' }
local SKIP = {
  ['scripts/terms.lua'] = true,
  ['scripts/terms_baseline.json'] = true,
  ['lua/fey/config/validate.lua'] = true, -- names the removed options to tell the user
  ['lua/fey/config/migrate.lua'] = true, -- names the old options and mappings to move them
  ['lua/fey/import/init.lua'] = true, -- the importers read org (and Markdown): the word is the name of the format
  ['lua/fey/import/org.lua'] = true, -- and the names of the nodes of the org grammar (headline, ...)
  ['lua/fey/import/writer.lua'] = true,
  ['scripts/fey_cli.lua'] = true,
}
local BASELINE = root .. '/scripts/terms_baseline.json'

---Count the uses of every old word in the files of the code
---@return table<string, table<string, integer>> counts by file, then by word
local function scan()
  local counts = {}
  for _, dir in ipairs(DIRS) do
    for _, path in ipairs(vim.fn.globpath(root .. '/' .. dir, '**/*', true, true)) do
      local rel = path:sub(#root + 2)
      if vim.fn.isdirectory(path) == 0 and not SKIP[rel] and not rel:match('%.bak$') and not rel:match('%.so$') then
        local ok, lines = pcall(vim.fn.readfile, path)
        if ok then
          for _, line in ipairs(lines) do
            local ignored = false
            for _, pattern in ipairs(IGNORE_LINE) do
              if line:find(pattern) then ignored = true end
            end
            for _, term in ipairs(not ignored and TERMS or {}) do
              for _, pattern in ipairs(term.patterns) do
                local _, n = line:gsub(pattern, '')
                if n > 0 then
                  counts[rel] = counts[rel] or {}
                  counts[rel][term.name] = (counts[rel][term.name] or 0) + n
                  break
                end
              end
            end
          end
        end
      end
    end
  end
  return counts
end

---@param counts table<string, table<string, integer>>
local function inventory(counts)
  local by_word = {}
  for file, words in pairs(counts) do
    for word, n in pairs(words) do
      by_word[word] = by_word[word] or { total = 0, files = {} }
      by_word[word].total = by_word[word].total + n
      table.insert(by_word[word].files, { file = file, n = n })
    end
  end
  for _, term in ipairs(TERMS) do
    local entry = by_word[term.name]
    print(
      ('%-20s -> %-34s %d use%s in %d file%s'):format(
        term.name,
        term.say,
        entry and entry.total or 0,
        entry and entry.total == 1 and '' or 's',
        entry and #entry.files or 0,
        entry and #entry.files == 1 and '' or 's'
      )
    )
    if entry then
      table.sort(entry.files, function(a, b) return a.n > b.n or (a.n == b.n and a.file < b.file) end)
      for i, f in ipairs(entry.files) do
        if i > 8 then
          print(('    ... and %d more files'):format(#entry.files - 8))
          break
        end
        print(('    %4d  %s'):format(f.n, f.file))
      end
    end
  end
end

local function read_baseline()
  local ok, lines = pcall(vim.fn.readfile, BASELINE)
  if not ok then return {} end
  local decoded_ok, data = pcall(vim.json.decode, table.concat(lines, '\n'))
  return decoded_ok and data or {}
end

local function sorted_json(counts)
  local files = vim.tbl_keys(counts)
  table.sort(files)
  local out = { '{' }
  for i, file in ipairs(files) do
    local words = vim.tbl_keys(counts[file])
    table.sort(words)
    local parts = {}
    for _, w in ipairs(words) do
      parts[#parts + 1] = ('%s: %d'):format(vim.json.encode(w), counts[file][w])
    end
    out[#out + 1] = ('  %s: { %s }%s'):format(vim.json.encode(file), table.concat(parts, ', '), i < #files and ',' or '')
  end
  out[#out + 1] = '}'
  return out
end

local mode = arg and arg[1] or ''
local counts = scan()

if mode == '--update' then
  vim.fn.writefile(sorted_json(counts), BASELINE)
  local total = 0
  for _, words in pairs(counts) do
    for _, n in pairs(words) do
      total = total + n
    end
  end
  print(('baseline written: %d uses in %d files'):format(total, vim.tbl_count(counts)))
  vim.cmd('qa!')
elseif mode == '--check' then
  local baseline = read_baseline()
  local worse, better = {}, 0
  for file, words in pairs(counts) do
    for word, n in pairs(words) do
      local was = baseline[file] and baseline[file][word] or 0
      if n > was then worse[#worse + 1] = ('%s: "%s" %d times, the baseline says %d'):format(file, word, n, was) end
    end
  end
  for file, words in pairs(baseline) do
    for word, was in pairs(words) do
      if (counts[file] and counts[file][word] or 0) < was then better = better + 1 end
    end
  end
  table.sort(worse)
  for _, w in ipairs(worse) do
    print('OLD WORD ' .. w)
  end
  if #worse > 0 then
    print(
      ('terms: %d new use%s of an old word. Say what the glossary says (see III.R), or if it has to stay, scripts/terms.lua --update.'):format(
        #worse,
        #worse == 1 and '' or 's'
      )
    )
    vim.cmd('cquit 1')
  end
  print(
    ('terms: no new use of an old word%s'):format(
      better > 0 and (' (%d count%s went down: run --update to keep it)'):format(better, better == 1 and '' or 's') or ''
    )
  )
  vim.cmd('qa!')
else
  inventory(counts)
  vim.cmd('qa!')
end
