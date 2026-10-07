-- The dates of a file as an iCalendar file: the scheduled dates, the deadlines and the active dates of the headings, from
-- the index. Dates with a time of day are floating local times, the others are all day events.
local M = {}

local function escape(s) return (s:gsub('\\', '\\\\'):gsub(';', '\\;'):gsub(',', '\\,'):gsub('\r?\n', '\\n')) end

---Lines are folded at 75 octets
---@param line string
---@return string[]
local function fold(line)
  local out = {}
  local rest = line
  while #rest > 75 do
    local cut = 75
    -- never inside a UTF-8 character
    while cut > 1 and rest:byte(cut + 1) and rest:byte(cut + 1) >= 0x80 and rest:byte(cut + 1) < 0xC0 do
      cut = cut - 1
    end
    out[#out + 1] = rest:sub(1, cut)
    rest = ' ' .. rest:sub(cut + 1)
  end
  out[#out + 1] = rest
  return out
end

local KIND_LABEL = { scheduled = 'SCHEDULED', deadline = 'DEADLINE', date = 'DATE' }

---@param ts integer
---@param with_time boolean
---@return string
local function stamp(ts, with_time) return os.date(with_time and '%Y%m%dT%H%M%S' or '%Y%m%d', ts) end

---@param rows table[] rows of `FeyVault:dates` (path, kind, active, start_ts, start_time, end_ts, end_time, heading_title, line)
---@param opts? { name?: string, now?: integer }
---@return string
function M.render(rows, opts)
  opts = opts or {}
  local out = { 'BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//fey.nvim//export//EN', 'CALSCALE:GREGORIAN' }
  if opts.name then out[#out + 1] = 'X-WR-CALNAME:' .. escape(opts.name) end
  local dtstamp = os.date('!%Y%m%dT%H%M%SZ', opts.now or os.time())
  for _, row in ipairs(rows) do
    local label = KIND_LABEL[row.kind]
    local active = row.active == 1 or row.active == true
    if label and active and row.start_ts then
      local with_time = row.start_time == 1 or row.start_time == true
      local lines = {
        'BEGIN:VEVENT',
        ('UID:%s@fey'):format(vim.fn.sha256(('%s:%d:%s:%d'):format(row.path or '', row.line or 0, row.kind, row.start_ts)):sub(1, 24)),
        'DTSTAMP:' .. dtstamp,
        'SUMMARY:' .. escape(('%s%s'):format(row.kind == 'date' and '' or (label:lower():gsub('^%l', string.upper) .. ': '), row.heading_title or row.path or '')),
        'DESCRIPTION:' .. escape(('%s of %s'):format(label, row.path or '')),
        'CATEGORIES:' .. label,
      }
      if with_time then
        lines[#lines + 1] = 'DTSTART:' .. stamp(row.start_ts, true)
        if row.end_ts then lines[#lines + 1] = 'DTEND:' .. stamp(row.end_ts, true) end
      else
        lines[#lines + 1] = 'DTSTART;VALUE=DATE:' .. stamp(row.start_ts, false)
        -- the end of an all day event is the day after its last day
        local last = row.end_ts or row.start_ts
        lines[#lines + 1] = 'DTEND;VALUE=DATE:' .. stamp(last + 86400, false)
      end
      lines[#lines + 1] = 'END:VEVENT'
      for _, l in ipairs(lines) do
        vim.list_extend(out, fold(l))
      end
    end
  end
  out[#out + 1] = 'END:VCALENDAR'
  return table.concat(out, '\r\n') .. '\r\n'
end

return M
