-- The clock. Clocks are tags in the logbook of a heading (see `fey.files.elements.logbook`), so the vault
-- knows them: one row of `dates` with `kind = clock` each, with no end while it runs. That is how the running
-- clock is found, in any file of any hollow, without loading anything; the time spent is a query.
--
-- Changing a clock is changing the heading's file, through `fey.agenda.edit`: the same code serves a mapping
-- in a document and the agenda.
local Duration = require('fey.objects.duration')
local Logbook = require('fey.files.elements.logbook')
local Edit = require('fey.agenda.edit')
local utils = require('fey.utils')
local Promise = require('fey.utils.promise')
local Input = require('fey.ui.input')

---@class FeyClockActive
---@field hollow string
---@field abs string
---@field path string
---@field line integer line of the heading
---@field ord integer
---@field title string
---@field signature string
---@field start_ts integer when the clock started
---@field clock_line integer

---@class FeyClock
---@field files FeyFiles
---@field private _active? FeyClockActive|false cached until the index changes
---@field private _closed? integer minutes in the finished clocks of the clocked heading
local Clock = {}

---@param opts? { files?: FeyFiles }
---@return FeyClock
function Clock:new(opts)
  opts = opts or {}
  local data = { files = opts.files }
  setmetatable(data, self)
  self.__index = self
  data:_setup()
  return data
end

---@private
function Clock:_setup()
  local group = vim.api.nvim_create_augroup('FeyClock', { clear = true })
  vim.api.nvim_create_autocmd('User', {
    group = group,
    pattern = { 'FeyVaultFileIndexed', 'FeyVaultIndexed' },
    callback = function() self:invalidate() end,
  })
  -- a clock that is still running when the editor quits: say so, it keeps running in the file
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = group,
    callback = function()
      local active = Clock.active()
      if active then
        vim.api.nvim_echo({ { ('Fey: the clock is still running in "%s"'):format(active.title), 'WarningMsg' } }, true, {})
      end
    end,
  })
end

---Forget what was read from the index
function Clock:invalidate()
  self._active, self._closed = nil, nil
end

---The running clock of the hollows of the court and of the hollow you are in, the latest started when there
---are more than one
---@return FeyClockActive|nil
function Clock.active()
  local tree = require('fey.hollow.tree')
  local name = vim.api.nvim_buf_get_name(0)
  local root = tree.hollow_root_of(name ~= '' and name or vim.fn.getcwd()) or tree.hollow_root_of(vim.fn.getcwd())
  local rows = require('fey.hollow.scope').collect({ 'court', 'current' }, root, function(vault)
    return vault:query(
      [[SELECT f.path, d.line AS clock_line, d.heading_ord AS ord, d.start_ts, h.title, h.line, h.signature
        FROM dates d JOIN files f ON f.id = d.file_id
        LEFT JOIN headings h ON h.file_id = d.file_id AND h.ord = d.heading_ord
        WHERE d.kind = 'clock' AND d.end_ts IS NULL AND d.heading_ord IS NOT NULL
        ORDER BY d.start_ts DESC]]
    )
  end)
  table.sort(rows, function(a, b) return a.start_ts > b.start_ts end)
  local row = rows[1]
  if not row then return nil end
  return {
    hollow = row.hollow,
    abs = row.abs,
    path = row.path,
    line = row.line or 1,
    ord = row.ord,
    title = row.title or '',
    signature = vim.trim(row.signature or ''),
    start_ts = row.start_ts,
    clock_line = row.clock_line,
  }
end

---@private
---@return FeyClockActive|nil
function Clock:_cached_active()
  if self._active == nil then self._active = Clock.active() or false end
  return self._active or nil
end

---Minutes in the finished clocks of a heading
---@param where { abs: string, ord: integer }
---@return integer
function Clock.closed_minutes(where)
  local vault = require('fey.vault').for_path(where.abs)
  if not vault then return 0 end
  local rel = vault:rel_of(where.abs)
  if not rel then return 0 end
  local rows = vault:query(
    [[SELECT d.start_ts, d.end_ts FROM dates d JOIN files f ON f.id = d.file_id
      WHERE f.path = :p AND d.heading_ord = :o AND d.kind = 'clock' AND d.end_ts IS NOT NULL]],
    { p = rel, o = where.ord }
  )
  local minutes = 0
  for _, r in ipairs(rows) do
    minutes = minutes + Duration.from_seconds(r.end_ts - r.start_ts).minutes
  end
  return minutes
end

---Run a function on a heading in its file
---@private
---@param source { abs: string, line: integer }
---@param fn fun(heading: FeyHeading): any
---@return FeyPromise
local function on_heading(source, fn)
  return Edit.run(source, function()
    return fn(require('fey').instance().files:get_closest_heading())
  end)
end

---Start a clock on a heading, stopping the one that runs
---@param source { abs: string, line: integer } the heading
---@return FeyPromise
function Clock:clock_in(source)
  local active = Clock.active()
  if active and active.abs == source.abs and active.line == source.line then
    utils.echo_info(('Clock continues in "%s"'):format(active.title))
    return Promise.resolve(false)
  end
  local stop = Promise.resolve()
  if active then
    stop = on_heading({ abs = active.abs, line = active.line }, function(heading) heading:clock_out() end)
  end
  return stop:next(function()
    return on_heading(source, function(heading)
      heading:clock_in()
      local now = os.date('%Y-%m-%d %H:%M')
      utils.echo_info(('Clock starts at %s'):format(now))
    end)
  end):next(function()
    self:invalidate()
    return true
  end)
end

---Stop the running clock, wherever it is
---@return FeyPromise
function Clock:clock_out()
  local active = Clock.active()
  if not active then
    utils.echo_info('No active clock')
    return Promise.resolve(false)
  end
  return on_heading({ abs = active.abs, line = active.line }, function(heading)
    local duration = Logbook.clock_out(heading)
    if duration then
      local events = require('fey.events')
      events.dispatch(events.event.ClockedOut:new(heading))
      utils.echo_info(('Clock stopped after %s'):format(duration:to_string('HH:MM')))
    end
  end):next(function()
    self:invalidate()
    return true
  end)
end

---Throw the running clock away
---@return FeyPromise
function Clock:clock_cancel()
  local active = Clock.active()
  if not active then
    utils.echo_info('No active clock')
    return Promise.resolve(false)
  end
  return on_heading({ abs = active.abs, line = active.line }, function(heading)
    heading:cancel_active_clock()
    utils.echo_info('Clock canceled')
  end):next(function()
    self:invalidate()
    return true
  end)
end

---Jump to the clocked heading
function Clock:clock_goto()
  local active = Clock.active()
  if not active then return utils.echo_info('No active clock') end
  utils.goto_heading({ abs = active.abs, line = active.line })
end

---Set the effort of a heading
---@param source { abs: string, line: integer }
---@return FeyPromise
function Clock:set_effort(source)
  return on_heading(source, function(heading)
    local current = heading:get_property('effort', false)
    return Input.open('Effort: ', current or ''):next(function(effort)
      if not effort then return false end
      if Duration.parse(effort) == nil then return utils.echo_error('Invalid duration format: ' .. effort) end
      heading:set_property('effort', effort)
      return true
    end)
  end)
end

-- The mappings of a document: the heading under the cursor

---@return { abs: string, line: integer }
local function here() return require('fey.refile').source_at_cursor() end

function Clock:fey_clock_in() return self:clock_in(here()) end

function Clock:fey_clock_out() return self:clock_out() end

function Clock:fey_clock_cancel() return self:clock_cancel() end

function Clock:fey_clock_goto() return self:clock_goto() end

function Clock:fey_set_effort() return self:set_effort(here()) end

---`(Fey) [1:20/2h] (Title)` for the statusline, empty when no clock runs
---@return string
function Clock:get_statusline()
  local active = self:_cached_active()
  if not active then return '' end
  if self._closed == nil then self._closed = Clock.closed_minutes(active) end
  local running = Duration.from_seconds(os.time() - active.start_ts).minutes
  local total = Duration.from_minutes(self._closed + running):to_string('HH:MM')
  local effort
  local vault = require('fey.vault').for_path(active.abs)
  if vault then
    local rel = vault:rel_of(active.abs)
    local row = rel and vault:query(
      [[SELECT h.props FROM headings h JOIN files f ON f.id = h.file_id WHERE f.path = :p AND h.ord = :o]],
      { p = rel, o = active.ord }
    )[1]
    local ok, props = pcall(vim.json.decode, row and row.props or '{}')
    effort = ok and props and props.effort or nil
  end
  if effort then return ('(Fey) [%s/%s] (%s)'):format(total, effort, active.title) end
  return ('(Fey) [%s] (%s)'):format(total, active.title)
end

return Clock
