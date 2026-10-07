-- Checkboxes of list items. The grammar has a `checkbox` node, the first thing of the contents of an item, and
-- accepts any single mark that is not a digit or a bracket: `[ ]`, `[x]`, `[/]`, `[!]`, `[n]`. What a mark
-- means is decided here. Progress cookies (`[1/3]`, `[33%]`) are plain text.
--
-- Every mark has a class, which is what the rules look at:
--
--   open       still to do: the space, and the marks of a task that waits, is scheduled, important, ...
--   active     under way: in progress, waiting for someone, delegated, in review, partly done
--   done       finished: `x` and `X`
--   cancelled  closed without being done: cancelled, rescheduled, duplicate. Left out of progress counts
--   info       a note about the text, not a task: a note, a location, an idea, a quote, a star ... Left out too
--
-- A parent item follows its children: all of those that count are done, it is done; none is done or under
-- way, it is open; anything between, it is under way (`[/]`).
--
-- Each mark also has two icons for the editor: a Nerd Font glyph (the codepoint in `nerd`) and a plain
-- Unicode symbol that has one cell in any font (`unicode`).
local M = {}

---@alias FeyCheckboxClass 'open'|'active'|'done'|'cancelled'|'info'

---@class FeyCheckboxState
---@field mark string the character between the brackets
---@field name string
---@field class FeyCheckboxClass
---@field nerd integer Nerd Font codepoint
---@field unicode string

---@param mark string
---@param name string
---@param class FeyCheckboxClass
---@param nerd integer
---@param unicode string
---@return FeyCheckboxState
local function s(mark, name, class, nerd, unicode) return { mark = mark, name = name, class = class, nerd = nerd, unicode = unicode } end

-- Symbols first, then the letters of the Primary theme of Obsidian, then a few more letters. The names and
-- classes follow the common Obsidian checkbox themes where they have a meaning.
---@type FeyCheckboxState[]
M.STATES = {
  s(' ', 'Open', 'open', 0xF096, '☐'),
  s('x', 'Done', 'done', 0xF046, '☑'),
  s('X', 'Done', 'done', 0xF046, '☑'),
  s('/', 'In progress', 'active', 0xF110, '◐'),
  s('-', 'Cancelled', 'cancelled', 0xF05E, '⊘'),
  s('>', 'Rescheduled', 'cancelled', 0xF064, '➜'),
  s('<', 'Scheduled', 'open', 0xF073, '◷'),
  s('!', 'Important', 'open', 0xF06A, '‼'),
  s('?', 'Question', 'open', 0xF059, '?'),
  s('*', 'Star', 'info', 0xF005, '★'),
  s('"', 'Quote', 'info', 0xF10D, '❝'),
  s('.', 'Someday', 'open', 0xF186, '☾'),
  s(',', 'Waiting', 'active', 0xF254, '⧗'),
  s(':', 'Delegated', 'active', 0xF007, '☺'),
  s(';', 'Deferred', 'open', 0xF04C, '‖'),
  s('+', 'New', 'open', 0xF067, '+'),
  s('=', 'Duplicate', 'cancelled', 0xF0C5, '≡'),
  s('~', 'In review', 'active', 0xF06E, '◉'),
  s('^', 'Escalated', 'open', 0xF148, '⇧'),
  s('@', 'Mention', 'info', 0xF1FA, '@'),
  s('#', 'Topic', 'info', 0xF292, '#'),
  s('$', 'Payment', 'open', 0xF09D, '$'),
  s('&', 'Related', 'info', 0xF0C1, '&'),
  s('%', 'Partly done', 'active', 0xF200, '◔'),
  -- the Primary theme
  s('n', 'Note', 'info', 0xF040, '✎'),
  s('l', 'Location', 'info', 0xF041, '⌖'),
  s('i', 'Information', 'info', 0xF05A, 'ⓘ'),
  s('S', 'Amount', 'info', 0xF155, '¤'),
  s('I', 'Idea', 'info', 0xF0EB, '✧'),
  s('p', 'Pro', 'info', 0xF087, '⊕'),
  s('c', 'Con', 'info', 0xF088, '⊖'),
  s('b', 'Bookmark', 'info', 0xF02E, '⚑'),
  s('u', 'Up', 'info', 0xF062, '↑'),
  s('d', 'Down', 'info', 0xF063, '↓'),
  s('r', 'Rule', 'info', 0xF0E3, '§'),
  s('L', 'Language', 'info', 0xF1AB, 'ℒ'),
  s('t', 'Time', 'info', 0xF017, '◴'),
  s('T', 'Telephone', 'info', 0xF095, '✆'),
  -- more letters
  s('a', 'Alert', 'info', 0xF0F3, '♪'),
  s('B', 'Bug', 'open', 0xF188, '✱'),
  s('C', 'Code', 'info', 0xF121, '⧉'),
  s('D', 'Decision', 'info', 0xF126, '⑂'),
  s('e', 'Experiment', 'open', 0xF0C3, '⚗'),
  s('E', 'Event', 'info', 0xF274, '◈'),
  s('f', 'Urgent', 'open', 0xF06D, '▲'),
  s('F', 'File', 'info', 0xF016, '▤'),
  s('g', 'Goal', 'info', 0xF140, '◎'),
  s('h', 'Favourite', 'info', 0xF004, '♥'),
  s('k', 'Key', 'info', 0xF084, '⚷'),
  s('m', 'Meeting', 'info', 0xF0C0, '≣'),
  s('M', 'Mail', 'info', 0xF0E0, '✉'),
  s('P', 'Person', 'info', 0xF2BE, '☻'),
  s('R', 'Reading', 'open', 0xF02D, '▦'),
  s('v', 'Video', 'info', 0xF03D, '▶'),
  s('w', 'Warning', 'info', 0xF071, '⚠'),
  s('W', 'Web', 'info', 0xF0AC, '◍'),
}

---@type table<string, FeyCheckboxState>
local by_mark = {}
for _, state in ipairs(M.STATES) do
  by_mark[state.mark] = state
end

---The state of a mark; a mark without a meaning is an open box
---@param mark string
---@return FeyCheckboxState
function M.state_of_mark(mark) return by_mark[mark] or by_mark[' '] end

---The mark of a box `[x]`
---@param text string
---@return string
function M.mark(text) return text:sub(2, 2) end

---@param text string `[ ]`, `[x]`, `[/]`, ...
---@return FeyCheckboxClass
function M.class(text) return M.state_of_mark(M.mark(text)).class end

---@param text string
---@return 'open'|'done'|'partial' the three states of the rules before marks had meanings, kept for callers
function M.state(text)
  local class = M.class(text)
  if class == 'done' then return 'done' end
  if class == 'active' then return 'partial' end
  return 'open'
end

---The glyph a mark is shown as
---@param mark string
---@param style 'nerd'|'unicode'
---@return string
function M.icon(mark, style)
  local state = M.state_of_mark(mark)
  if style == 'nerd' then return vim.fn.nr2char(state.nerd) end
  return state.unicode
end

---Does a box count in progress: tasks do, notes and cancelled ones do not
---@param class FeyCheckboxClass
---@return boolean
local function counts(class) return class == 'open' or class == 'active' or class == 'done' end

---Boxes that are done, and boxes that count
---@param boxes string[]
---@return integer checked
---@return integer total
function M.progress(boxes)
  local checked, total = 0, 0
  for _, box in ipairs(boxes) do
    local class = M.class(box)
    if counts(class) then
      total = total + 1
      if class == 'done' then checked = checked + 1 end
    end
  end
  return checked, total
end

---The box an item gets
---@param action string `toggle`, `on`, `off`, `children`, or `mark:x` for a given mark
---@param current string the box now
---@param boxes string[] the boxes of the items below it, for `children`
---@return string
function M.next(action, current, boxes)
  if action:sub(1, 5) == 'mark:' then return '[' .. action:sub(6, 6) .. ']' end
  if action == 'on' then return '[X]' end
  if action == 'off' then return '[ ]' end
  if action == 'toggle' then return M.class(current) == 'done' and '[ ]' or '[X]' end
  -- children
  local checked, total = M.progress(boxes)
  if total == 0 then return current end
  if checked == total then return '[X]' end
  local active = false
  for _, box in ipairs(boxes) do
    if M.class(box) == 'active' then active = true end
  end
  if checked == 0 and not active then return '[ ]' end
  return '[/]'
end

---A cookie with the same shape (`[1/3]` or `[33%]`) for new numbers
---@param cookie string
---@param checked integer
---@param total integer
---@return string
function M.cookie(cookie, checked, total)
  if cookie:find('%%') then
    local percent = total > 0 and math.floor(checked / total * 100 + 0.5) or 0
    return ('[%d%%]'):format(percent)
  end
  return ('[%d/%d]'):format(checked, total)
end

---Is a piece of text a progress cookie
---@param text string
---@return boolean
function M.is_cookie(text) return text:match('^%[%d*/%d*%]$') ~= nil or text:match('^%[%d?%d?%d?%%%]$') ~= nil end

return M
