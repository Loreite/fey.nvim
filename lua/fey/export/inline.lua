-- Inline text of a paragraph: the emphasis markers of the markup (`!bold!`, `/italic/`, `_underline_`, `~strike~`, `` `code` ``)
-- become spans. A marker opens at the start or after a blank or an opening bracket and quote, with text right after it, and closes after
-- text, at the end or before a blank, a closing bracket or punctuation; that keeps paths (`a/b/c`) and words (`snake_case`) as they are.
local M = {}

local KINDS = { ['!'] = 'bold', ['/'] = 'italic', ['_'] = 'underline', ['~'] = 'strike', ['`'] = 'code' }

local function opens(text, i)
  local before = i == 1 and ' ' or text:sub(i - 1, i - 1)
  local after = text:sub(i + 1, i + 1)
  return (before:match('[%s%(%[{"\']') ~= nil) and after ~= '' and not after:match('%s')
end

local function closes(text, i, marker)
  local before = text:sub(i - 1, i - 1)
  local after = text:sub(i + 1, i + 1)
  return before ~= '' and not before:match('%s') and before ~= marker and (after == '' or after:match('[%s%)%]}"\'%.,;:!?]') ~= nil)
end

---Split plain text into inline items: `{ t = 'text', s }` and `{ t = 'em', kind, children }`, `{ t = 'code', s }`
---@param text string
---@return table[]
function M.parse(text)
  local out = {}
  local pos, i = 1, 1
  local function flush(upto)
    if upto >= pos then out[#out + 1] = { t = 'text', s = text:sub(pos, upto) } end
  end
  while i <= #text do
    local c = text:sub(i, i)
    if c == '\\' then
      i = i + 2
    elseif KINDS[c] and opens(text, i) then
      local j = i + 1
      local found
      while j <= #text do
        local d = text:sub(j, j)
        if d == '\\' then
          j = j + 2
        elseif d == c and closes(text, j, c) then
          found = j
          break
        else
          j = j + 1
        end
      end
      if found then
        flush(i - 1)
        local inner = text:sub(i + 1, found - 1)
        if KINDS[c] == 'code' then
          out[#out + 1] = { t = 'code', s = inner }
        else
          out[#out + 1] = { t = 'em', kind = KINDS[c], children = M.parse(inner) }
        end
        pos, i = found + 1, found + 1
      else
        i = i + 1
      end
    else
      i = i + 1
    end
  end
  flush(#text)
  -- a backslash escapes the next character
  local function unescape(items)
    for _, item in ipairs(items) do
      if item.t == 'text' then item.s = item.s:gsub('\\(.)', '%1') end
      if item.children then unescape(item.children) end
    end
  end
  unescape(out)
  return out
end

return M
