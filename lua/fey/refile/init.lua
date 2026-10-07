-- Moving a heading, with everything below it, to another place: another heading (it becomes a child of it),
-- or the end of any file of the hollows. Archiving is a refile to the archive file of the document.
--
--   local refile = require('fey.refile')
--   refile.at_cursor()                      -- pick a destination, move the heading under the cursor
--   refile.move(source, destination)        -- both are { abs, line? } tables, see below
--   refile.archive_at_cursor()
--
-- The source is `{ abs, line }`, the line of a heading. A destination is `{ abs }` for the end of a file
-- (the moved heading becomes a top level heading) or `{ abs, line, end_line, level }` for a heading of the
-- index, which the moved heading is put under, as its last child. The levels are adapted with the same
-- promote/demote the document mappings use, and the signatures are renumbered in the destination and in
-- the source (`FeyFile:reindex_headings`).
--
-- The text is edited through `fey.agenda.edit`: a buffer with unsaved changes is changed and left unsaved,
-- every other file is written and indexed again.
local Edit = require('fey.agenda.edit')
local Promise = require('fey.utils.promise')
local config = require('fey.config')

local M = {}

---@class FeyRefileSource
---@field abs string
---@field line integer line of the heading
---@field hollow? string

---@class FeyRefileDestination
---@field abs string
---@field line? integer line of the destination heading, none for the end of the file
---@field end_line? integer last line of the destination heading, with its subsections
---@field level? integer level of the destination heading
---@field hollow? string
---@field signature? string
---@field title? string

local function realpath(path) return vim.uv.fs_realpath(path) or path end

---Where the subtree of a heading is in its buffer
---@param heading FeyHeading
---@return integer first 1-based first line
---@return integer last 1-based last line of the subtree
function M.subtree(heading)
  local sr, _, er, ec = heading:node():parent():range()
  return sr + 1, ec == 0 and er or er + 1
end

---The heading of the buffer under the cursor, and where its subtree is
---@return FeyHeading heading
---@return integer first 1-based first line
---@return integer last 1-based last line of the subtree
local function heading_here()
  local heading = require('fey').instance().files:get_closest_heading()
  local first, last = M.subtree(heading)
  return heading, first, last
end

---The lines of a heading and its subtree at another level, the heading being the one under the cursor
---@param heading FeyHeading
---@param new_level integer the level the heading gets (1 is the top level)
---@return string[]
local function lines_at_level(heading, new_level)
  local diff = new_level - heading:get_level()
  if diff > 0 then return heading:demote(diff, true, true) end
  if diff < 0 then return heading:promote(-diff, true, true) end
  return heading:get_lines()
end

---Text whose first heading is moved to another level: parsed in a buffer of its own, so that it is not
---mixed with the headings of the file it goes into
---@param lines string[]
---@param new_level integer
---@return string[]
local function adapt_lines(lines, new_level)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. '.fey')
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = 'fey'
  local ok, result = pcall(vim.api.nvim_buf_call, buf, function()
    local files = require('fey').instance().files
    vim.fn.cursor({ 1, 1 })
    local heading = files:get_closest_heading({ 1, 0 })
    if heading:get_range().start_line ~= 1 then return lines end
    return lines_at_level(heading, new_level)
  end)
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  return ok and result or lines
end

---@param lines string[]
---@return string[]
local function trim_blank_ends(lines)
  local first, last = 1, #lines
  while first <= last and lines[first]:match('^%s*$') do first = first + 1 end
  while last >= first and lines[last]:match('^%s*$') do last = last - 1 end
  return vim.list_slice(lines, first, last)
end

---Put lines at the end of a heading's subtree (or of the file) after its last text line, with a blank line between
---@param buf integer
---@param lines string[]
---@param after_line? integer last line of the subtree (1-based), default the end of the file
---@param exact? boolean put the lines right after `after_line`, do not skip back over blank lines
---@param bare? boolean no blank line between what is there and the lines
---@return integer first line of the inserted text (1-based)
local function insert_block(buf, lines, after_line, exact, bare)
  local all = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local at = math.min(after_line or #all, #all)
  while not exact and at > 0 and all[at]:match('^%s*$') do at = at - 1 end
  local block = (at > 0 and not bare) and vim.list_extend({ '' }, lines) or vim.deepcopy(lines)
  vim.api.nvim_buf_set_lines(buf, at, at, false, block)
  return at + (at > 0 and 2 or 1)
end

---Remove lines `first` to `last` and the blank lines that separated them from what follows
---@param buf integer
---@param first integer
---@param last integer
local function remove_block(buf, first, last)
  local all = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local stop = last
  while stop < #all and all[stop + 1]:match('^%s*$') do stop = stop + 1 end
  -- keep one blank line between what is left, none at the very end or start
  if stop >= #all or first == 1 then
    vim.api.nvim_buf_set_lines(buf, first - 1, stop, false, {})
  else
    vim.api.nvim_buf_set_lines(buf, first - 1, stop - 1, false, {})
  end
end

---@param signature_of fun(): string
local function current_signature()
  local heading = require('fey').instance().files:get_closest_heading()
  return vim.trim(vim.treesitter.get_node_text(heading:get_child_node('signature'), 0))
end

---Reindex the signatures of the document of the current buffer
local function reindex_current()
  local file = require('fey').instance().files:get_current_file()
  file:reindex_headings()
end

---Move a heading and its subtree
---@param source FeyRefileSource
---@param destination FeyRefileDestination
---@param opts? { leave_link?: boolean, props?: table<string, string>, message?: string } `props` are written as props of the moved heading
---@return FeyPromise result `{ signature, line }` of the heading in its new place
function M.move(source, destination, opts)
  opts = opts or {}
  local same_file = realpath(source.abs) == realpath(destination.abs)
  local target_level = destination.level and destination.level + 1 or 1
  local tree = require('fey.hollow.tree')

  -- inbound references to what is moved, to say they are left behind
  local src_hollow_root = tree.hollow_root_of(source.abs)
  local old_signature, old_path
  local moved = {}

  local function collect()
    return Edit.run(source, function()
      local heading, first, last = heading_here()
      old_signature = vim.trim(vim.treesitter.get_node_text(heading:get_child_node('signature'), 0))
      moved.title = heading:get_title()
      moved.lines = lines_at_level(heading, target_level)
      moved.first, moved.last = first, last
      moved.outline = heading:get_heading_path()
      moved.state = heading:get_todo()
      old_path = moved.outline
    end)
  end

  if destination.line and same_file then
    -- a heading cannot go below itself
    local ok_range = Edit.run(source, function()
      local _, first, last = heading_here()
      if destination.line >= first and destination.line <= last then error('Cannot refile a heading into itself', 0) end
    end)
    local pre = ok_range
    local result = pre:next(function() return collect() end)
    return result:next(function() return M._insert_and_remove(source, destination, moved, opts, same_file, src_hollow_root, old_signature) end)
  end

  return collect():next(function()
    return M._insert_and_remove(source, destination, moved, opts, same_file, src_hollow_root, old_signature)
  end)
end

---@private
function M._insert_and_remove(source, destination, moved, opts, same_file, src_hollow_root, old_signature)
  local tree = require('fey.hollow.tree')
  local new = {}
  local lines = trim_blank_ends(moved.lines)

  local function backlinks_left()
    if not src_hollow_root or not old_signature then return 0 end
    local ok, rows = pcall(function()
      local rel = vim.fs.relpath(src_hollow_root, realpath(source.abs))
      return require('fey.hollow.scope').backlinks('court', src_hollow_root, src_hollow_root, rel, old_signature)
    end)
    return ok and #rows or 0
  end
  local inbound = backlinks_left()

  local function link_lines()
    if not opts.leave_link then return nil end
    local dest_root = tree.hollow_root_of(destination.abs)
    local rel = dest_root and vim.fs.relpath(dest_root, realpath(destination.abs)) or destination.abs
    local target = rel
    if dest_root ~= src_hollow_root then
      local id = tree.id_of(dest_root)
      if id then target = id .. '/' .. rel end
    end
    return { require('fey.api').link_text(target, { desc = moved.title, section = new.signature }) }
  end

  local function insert()
    if same_file then
      return Edit.run(source, function()
        local buf = vim.api.nvim_get_current_buf()
        local _, first, last = heading_here()
        remove_block(buf, first, last)
        local removed = last - first + 1
        local dest_end
        if destination.line then
          dest_end = destination.end_line
          if destination.end_line > last then dest_end = dest_end - removed end
        end
        new.line = insert_block(buf, lines, dest_end)
        vim.fn.cursor({ new.line, 1 })
        reindex_current()
        new.signature = current_signature()
        if opts.props then
          local h = require('fey').instance().files:get_closest_heading({ new.line, 0 })
          for k, v in pairs(opts.props) do h:set_property(k, v) end
        end
      end)
    end
    return Edit.run({ abs = destination.abs, line = 1 }, function()
      local buf = vim.api.nvim_get_current_buf()
      new.line = insert_block(buf, lines, destination.line and destination.end_line or nil)
      vim.fn.cursor({ new.line, 1 })
      reindex_current()
      new.signature = current_signature()
      if opts.props then
        local h = require('fey').instance().files:get_closest_heading({ new.line, 0 })
        for k, v in pairs(opts.props) do h:set_property(k, v) end
      end
    end)
  end

  local function remove()
    if same_file then return Promise.resolve() end
    return Edit.run(source, function()
      local buf = vim.api.nvim_get_current_buf()
      local _, first, last = heading_here()
      remove_block(buf, first, last)
      local link = link_lines()
      if link then
        local at = math.max(first - 1, 0)
        vim.api.nvim_buf_set_lines(buf, at, at, false, vim.list_extend(vim.list_slice(link, 1), { '' }))
      end
      reindex_current()
    end)
  end

  return insert():next(function() return remove() end):next(function()
    return { signature = new.signature, line = new.line, inbound = inbound, message = opts.message }
  end)
end

---Insert text into a file. The text is put at the end of the destination heading's subtree (or of the
---file), after the line that matches `regexp`, or right under the destination heading when `reversed`.
---The file is changed the way `move` changes it: through its buffer, then saved and indexed again.
---@param destination FeyRefileDestination `resolve`, when there is one, runs in the buffer of the file and returns fields that complete the destination (a date tree puts its headings in first)
---@param lines string[]
---@param opts? { adapt?: boolean, regexp?: string, reversed?: boolean, props?: table<string, string>, pad?: { before?: integer, after?: integer } } `pad` adds blank lines around the text; `adapt` makes the first heading of the text a child of the destination heading (or a top level one)
---@return FeyPromise result `{ signature, line }` where the text is
function M.insert(destination, lines, opts)
  opts = opts or {}
  lines = trim_blank_ends(lines)
  local pad = opts.pad or {}
  for _ = 1, pad.before or 0 do
    table.insert(lines, 1, '')
  end
  for _ = 1, pad.after or 0 do
    lines[#lines + 1] = ''
  end
  return Edit.run({ abs = destination.abs, line = 1 }, function()
    local buf = vim.api.nvim_get_current_buf()
    local dest = destination
    if destination.resolve then dest = vim.tbl_extend('force', destination, destination.resolve() or {}) end

    local after, exact, bare
    if dest.line and opts.reversed then
      after, exact = dest.line, true
    elseif dest.line then
      after = dest.end_line
    elseif opts.regexp then
      local found = vim.fn.search(opts.regexp, 'ncw')
      if found > 0 then after, exact, bare = found, true, true end
    end
    if opts.adapt then lines = adapt_lines(trim_blank_ends(lines), dest.level and dest.level + 1 or 1) end
    local first = insert_block(buf, lines, after, exact, bare)
    -- the text may start with blank lines (padding, a separating line)
    local all = vim.api.nvim_buf_get_lines(buf, first - 1, -1, false)
    for i = 1, #all do
      if all[i]:match('%S') then
        first = first + i - 1
        break
      end
    end
    vim.fn.cursor({ first, 1 })

    local files = require('fey').instance().files
    reindex_current()
    local ok, heading = pcall(files.get_closest_heading, files, { first, 0 })
    local signature = ok and heading and heading:get_range().start_line == first and current_signature() or ''
    if opts.props and signature ~= '' then
      for k, v in pairs(opts.props) do heading:set_property(k, v) end
    end
    return { signature = signature, line = first }
  end)
end

-- Destinations -------------------------------------------------------------------------------------

---The places a heading can be refiled to: every file and every heading of the hollows of the scope
---@param spec? FeyScopeSpec default `fey_refile_scope`, else `court`
---@param root? string the hollow `current` and `tree` start from
---@return { text: string, dest: FeyRefileDestination }[]
function M.destinations(spec, root)
  spec = spec or config.fey_refile_scope or 'court'
  if spec == 'court' and not require('fey.hollow.court').root() then spec = 'current' end
  root = root or require('fey.hollow.tree').hollow_root_of(vim.fn.getcwd())
  local scope = require('fey.hollow.scope')
  local files = scope.collect(spec, root, function(vault) return vault:files() end)
  local headings = scope.collect(spec, root, function(vault)
    return vault:query(
      [[SELECT f.path, h.ord, h.line, h.end_line, h.level, h.signature, h.title FROM headings h
        JOIN files f ON f.id = h.file_id ORDER BY f.path, h.ord]]
    )
  end)
  local out = {}
  for _, row in ipairs(files) do
    if not row.path:match('%.fey_archive$') then
      out[#out + 1] = {
        text = ('%s/%s'):format(row.hollow, row.path),
        dest = { abs = row.abs, hollow = row.hollow },
      }
    end
  end
  for _, row in ipairs(headings) do
    if not row.path:match('%.fey_archive$') then
      out[#out + 1] = {
        text = ('%s/%s  %s %s'):format(row.hollow, row.path, vim.trim(row.signature or ''), row.title or ''),
        dest = {
          abs = row.abs,
          hollow = row.hollow,
          line = row.line,
          end_line = row.end_line,
          level = row.level,
          signature = vim.trim(row.signature or ''),
          title = row.title,
        },
      }
    end
  end
  return out
end

---Ask for a destination
---@param opts? { scope?: FeyScopeSpec, root?: string, prompt?: string }
---@return FeyPromise destination `FeyRefileDestination`, or false when cancelled
function M.pick(opts)
  opts = opts or {}
  local candidates = M.destinations(opts.scope, opts.root)
  local items, by_text = {}, {}
  for _, c in ipairs(candidates) do
    items[#items + 1] = { text = c.text }
    by_text[c.text] = c.dest
  end
  return Promise.new(function(resolve)
    require('fey.ui.fuzzy').open({
      prompt = opts.prompt or 'Refile to',
      items = items,
      on_confirm = function(item) resolve(item and by_text[item.text] or false) end,
      on_cancel = function() resolve(false) end,
    })
  end)
end

-- Entry points --------------------------------------------------------------------------------------

---@param result table|false|nil
---@param verb string
local function report(result, verb)
  if not result then return end
  local utils = require('fey.utils')
  local msg = ('%s to %s'):format(verb, result.signature or '')
  if result.inbound and result.inbound > 0 then
    msg = msg .. ('; %d link%s to the old place not rewritten'):format(result.inbound, result.inbound == 1 and '' or 's')
  end
  utils.echo_info(msg)
end

---Refile the heading described by `source`, asking for the destination
---@param source FeyRefileSource
---@param opts? { scope?: FeyScopeSpec }
---@return FeyPromise
function M.refile(source, opts)
  opts = opts or {}
  return M.pick(opts):next(function(destination)
    if not destination then return false end
    return M.move(source, destination, { leave_link = config.fey_refile_leave_link }):next(function(result)
      report(result, 'Refiled')
      return result
    end)
  end)
end

---The heading under the cursor of a document, as a source
---@return FeyRefileSource
function M.source_at_cursor()
  local heading = require('fey').instance().files:get_closest_heading()
  return {
    abs = realpath(vim.api.nvim_buf_get_name(0)),
    line = heading:get_range().start_line,
  }
end

---Refile the heading under the cursor (the mapping `fey_refile`)
function M.at_cursor()
  local ok, source = pcall(M.source_at_cursor)
  if not ok then return require('fey.utils').echo_error('No heading here') end
  return M.refile(source):next(nil, function(err)
    if err then require('fey.utils').echo_error(tostring(type(err) == 'table' and err.message or err)) end
  end)
end

-- Archive -------------------------------------------------------------------------------------------

---The archive file of a document: `fey_archive_location` is a template, `%s` is the file name
---@param abs string
---@return string|nil
function M.archive_location(abs) return config:parse_archive_location(abs) end

---Move a heading to the archive file of its document and note where it came from in props:
---`archived_from` (hollow and file), `archived_path` (titles above it), `archived_at`, `archived_state`
---@param source FeyRefileSource
---@return FeyPromise
function M.archive(source)
  local location = M.archive_location(source.abs)
  if not location then
    require('fey.utils').echo_warning('This file is already an archive file.')
    return Promise.resolve(false)
  end
  vim.fn.mkdir(vim.fn.fnamemodify(location, ':p:h'), 'p')
  if not vim.uv.fs_stat(location) then vim.fn.writefile({}, location) end
  location = realpath(location)

  local tree = require('fey.hollow.tree')
  local root = tree.hollow_root_of(source.abs)
  local id = root and tree.id_of(root)
  local rel = root and vim.fs.relpath(root, realpath(source.abs)) or source.abs
  local props = { archived_from = id and (id .. '/' .. rel) or rel, archived_at = require('fey.objects.date').now():to_string() }

  -- what is written needs the heading before it is moved
  local outline, state
  return Edit.run(source, function()
    local heading = heading_here()
    outline, state = heading:get_heading_path(), heading:get_todo()
  end):next(function()
    if outline and outline ~= '' then props.archived_path = outline end
    if state then props.archived_state = state end
    return M.move(source, { abs = location }, { props = props })
  end):next(function(result)
    local utils = require('fey.utils')
    utils.echo_info(('Archived to %s'):format(vim.fn.fnamemodify(location, ':t')))
    return result
  end)
end

---Archive the heading under the cursor (the mapping `fey_archive_subtree`)
function M.archive_at_cursor()
  local ok, source = pcall(M.source_at_cursor)
  if not ok then return require('fey.utils').echo_error('No heading here') end
  return M.archive(source):next(nil, function(err)
    if err then require('fey.utils').echo_error(tostring(type(err) == 'table' and err.message or err)) end
  end)
end

return M
