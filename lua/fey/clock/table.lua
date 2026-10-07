-- The clocktable: a dynamic block. A `clocktable` tag has the lifecycle of a `query` tag (it runs from the query
-- mappings and when a buffer loads) and writes a table into a `clocktable_result` pair tag after it. It is a
-- query over the clocks of the vault (the `kind = clock` rows of `dates`).
--
--   {# clocktable; span: thisweek; by: heading; scope: tree #}
--   [ clocktable_result #]
--   | Heading     | Time |
--   +=============+======+
--   | {@ link ... @} | 3:30 |
--   | Total       | 3:30 |
--   [# clocktable_result ]
--
-- `span`, or the first plain value: today, yesterday, thisweek (default), lastweek, thismonth, lastmonth, thisyear,
-- lastyear, all, `7d` for the last 7 days, `2026`, `2026-10`, `2026-10-07`, or two of those, `2026-10-01--2026-10-07`.
-- `by`: heading (default), file or day. `scope`: as the scope of a query tag. A clock counts when it is finished and
-- starts or ends in the span.
local Date = require('fey.objects.date')
local Duration = require('fey.objects.duration')

local M = {}

local FAR = 4102444800 -- 2100-01-01

---Start and end of a span of days, as timestamps
---@param text string
---@return integer|nil from
---@return integer|string to_or_error
function M.parse_span(text)
  text = vim.trim(text or ''):lower()
  if text == '' then text = 'thisweek' end
  local today = Date.today()
  local function day(d) return d:start_of('day') end
  local function stamp(from, to) return from.timestamp, to:end_of('day').timestamp end

  if text == 'all' then return 0, FAR end
  if text == 'today' then return stamp(day(today), today) end
  if text == 'yesterday' then
    local d = day(today:adjust('-1d'))
    return stamp(d, d)
  end
  if text == 'thisweek' then return stamp(today:start_of('week'), today:end_of('week')) end
  if text == 'lastweek' then
    local d = today:adjust('-7d')
    return stamp(d:start_of('week'), d:end_of('week'))
  end
  if text == 'thismonth' then return stamp(today:set({ day = 1 }), today:end_of('month')) end
  if text == 'lastmonth' then
    local d = today:set({ day = 1 }):adjust('-1d')
    return stamp(d:set({ day = 1 }), d:end_of('month'))
  end
  if text == 'thisyear' then return stamp(today:start_of('year'), today:end_of('year')) end
  if text == 'lastyear' then
    local d = today:set({ year = today.year - 1 })
    return stamp(d:start_of('year'), d:end_of('year'))
  end
  local days = text:match('^(%d+)d$')
  if days then return stamp(day(today:adjust('-' .. (tonumber(days) - 1) .. 'd')), today) end

  local function bound(part, last)
    local y, m, d = part:match('^(%d%d%d%d)-(%d%d)-(%d%d)$')
    if y then return Date.from_timestamp(os.time({ year = y, month = m, day = d, hour = 12 })) end
    y, m = part:match('^(%d%d%d%d)-(%d%d)$')
    if y then
      local first = Date.from_timestamp(os.time({ year = y, month = m, day = 1, hour = 12 }))
      return last and first:end_of('month') or first
    end
    y = part:match('^(%d%d%d%d)$')
    if y then
      local first = Date.from_timestamp(os.time({ year = y, month = 1, day = 1, hour = 12 }))
      return last and first:end_of('year') or first
    end
  end
  local a, b = text:match('^(.-)%-%-(.+)$')
  local first, last = bound(a or text, false), bound(b or text, true)
  if not first or not last then return nil, ('clocktable: unknown span "%s"'):format(text) end
  return day(first).timestamp, last:end_of('day').timestamp
end

---@class FeyClockTableSpec
---@field span? string
---@field by? 'heading'|'file'|'day'
---@field scope? FeyScopeSpec

---The lines of a clocktable
---@param vault FeyVault
---@param spec FeyClockTableSpec
---@param opts? FeyQueryRenderOpts
---@return string[]
function M.lines(vault, spec, opts)
  opts = opts or {}
  local from, to = M.parse_span(spec.span)
  if not from then error(to, 0) end
  local by = (spec.by or 'heading'):lower()
  if by ~= 'heading' and by ~= 'file' and by ~= 'day' then error(('clocktable: unknown "by": %s'):format(by), 0) end

  local rows = require('fey.hollow.scope').dates(spec.scope, vault.root, { kinds = { 'clock' }, from = from, to = to })
  local V = require('fey.query.values')
  local groups, order = {}, {}
  local total = 0
  for _, row in ipairs(rows) do
    local inside = (row.start_ts >= from and row.start_ts <= to) or (row.end_ts and row.end_ts >= from and row.end_ts <= to)
    if row.end_ts and inside and row.heading_ord then
      local minutes = Duration.from_seconds(row.end_ts - row.start_ts).minutes
      local key, label
      local file = vim.fn.fnamemodify(row.path, ':r')
      if by == 'file' then
        key, label = row.hollow .. '\0' .. row.path, V.link(row.path, file, nil, row.hollow)
      elseif by == 'day' then
        key = os.date('%Y-%m-%d %a', row.start_ts)
        label = key
      else
        key = row.hollow .. '\0' .. row.path .. '\0' .. row.heading_ord
        label = V.link(row.path, row.heading_title, row.signature, row.hollow)
      end
      if not groups[key] then
        groups[key] = { label = label, minutes = 0, file = file }
        order[#order + 1] = key
      end
      groups[key].minutes = groups[key].minutes + minutes
      total = total + minutes
    end
  end
  table.sort(order)
  if #order == 0 then return { 'No clocks to show for this span.' } end

  local first_header = ({ heading = 'Heading', file = 'File', day = 'Day' })[by]
  local body = {}
  for _, key in ipairs(order) do
    body[#body + 1] = { groups[key].label, Duration.from_minutes(groups[key].minutes):to_string() }
  end
  body[#body + 1] = { 'Total', Duration.from_minutes(total):to_string() }
  return require('fey.query.render').lines(
    { type = 'table', count = #body, headers = { first_header, 'Time' }, rows = body },
    opts
  )
end

return M
