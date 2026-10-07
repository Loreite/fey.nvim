-- Labels as superscript text: `12` becomes `¹²`. Neovim cannot ask a font which characters it has, so the
-- digits and the signs of arithmetic, which nearly every font draws, are separate from the letters, which
-- many do not (the Phonetic Extensions block): `fey_footnote_superscript = 'auto'` converts only the first
-- group, `true` also the letters that have a superscript, `false` never. A label that cannot be written whole
-- is left as it is.
local M = {}

local SAFE = {
  ['0'] = '⁰', ['1'] = '¹', ['2'] = '²', ['3'] = '³', ['4'] = '⁴', ['5'] = '⁵', ['6'] = '⁶', ['7'] = '⁷',
  ['8'] = '⁸', ['9'] = '⁹', ['+'] = '⁺', ['-'] = '⁻', ['='] = '⁼', ['('] = '⁽', [')'] = '⁾',
}

local LETTERS = {
  a = 'ᵃ', b = 'ᵇ', c = 'ᶜ', d = 'ᵈ', e = 'ᵉ', f = 'ᶠ', g = 'ᵍ', h = 'ʰ', i = 'ⁱ', j = 'ʲ', k = 'ᵏ', l = 'ˡ',
  m = 'ᵐ', n = 'ⁿ', o = 'ᵒ', p = 'ᵖ', r = 'ʳ', s = 'ˢ', t = 'ᵗ', u = 'ᵘ', v = 'ᵛ', w = 'ʷ', x = 'ˣ', y = 'ʸ',
  z = 'ᶻ',
  A = 'ᴬ', B = 'ᴮ', D = 'ᴰ', E = 'ᴱ', G = 'ᴳ', H = 'ᴴ', I = 'ᴵ', J = 'ᴶ', K = 'ᴷ', L = 'ᴸ', M = 'ᴹ', N = 'ᴺ',
  O = 'ᴼ', P = 'ᴾ', R = 'ᴿ', T = 'ᵀ', U = 'ᵁ', V = 'ⱽ', W = 'ᵂ',
}

---@param mode? 'auto'|boolean
---@return boolean
function M.enabled(mode) return mode ~= false end

---The label as superscript, nil when it cannot be written whole (or the setting is off)
---@param label string
---@param mode? 'auto'|boolean `auto` digits and signs only, `true` letters too, `false` off
---@return string|nil
function M.convert(label, mode)
  if mode == false or label == '' then return nil end
  local out = {}
  for _, ch in ipairs(vim.fn.split(label, '\\zs')) do
    local sup = SAFE[ch] or (mode == true and LETTERS[ch]) or nil
    if not sup then return nil end
    out[#out + 1] = sup
  end
  return table.concat(out)
end

return M
