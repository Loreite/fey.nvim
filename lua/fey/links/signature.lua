-- Heading signatures as `section` tags refer to them: only the tokens count, every
-- delimiter matches (`IV.A.iii.`, `IV,A,iii` and `IV:A:iii:` are the same signature).
local M = {}

---@param sig string
---@return string[] tokens one per segment, anonymous segments are ''
function M.tokens(sig)
  sig = vim.trim(sig)
  local out, acc = {}, {}
  for ch in sig:gmatch('.') do
    if ch:match('[%w_]') then
      acc[#acc + 1] = ch
    else
      out[#out + 1] = table.concat(acc)
      acc = {}
    end
  end
  if #acc > 0 then out[#out + 1] = table.concat(acc) end
  return out
end

---Normalised form, usable as a lookup key
---@param sig string
---@return string
function M.key(sig) return table.concat(M.tokens(sig), '.') end

---@param a string
---@param b string
function M.equal(a, b) return M.key(a) == M.key(b) end

return M
