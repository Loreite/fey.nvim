-- lua/fey/sequences.lua
local M = {}

local function to_roman(num)
  local map = {
    { 1000, 'M' },
    { 900, 'CM' },
    { 500, 'D' },
    { 400, 'CD' },
    { 100, 'C' },
    { 90, 'XC' },
    { 50, 'L' },
    { 40, 'XL' },
    { 10, 'X' },
    { 9, 'IX' },
    { 5, 'V' },
    { 4, 'IV' },
    { 1, 'I' },
  }
  local result = ''
  for _, entry in ipairs(map) do
    while num >= entry[1] do
      result = result .. entry[2]
      num = num - entry[1]
    end
  end
  return result
end

local function from_roman(str)
  local map = { I = 1, V = 5, X = 10, L = 50, C = 100, D = 500, M = 1000 }
  local total, prev = 0, 0
  str = str:upper()
  for i = #str, 1, -1 do
    local val = map[str:sub(i, i)] or 0
    if val < prev then
      total = total - val
    else
      total = total + val
    end
    prev = val
  end
  return total
end

local function to_alpha(num)
  local result = ''
  while num > 0 do
    local rem = (num - 1) % 26
    result = string.char(65 + rem) .. result
    num = math.floor((num - 1) / 26)
  end
  return result
end

local function from_alpha(str)
  local total = 0
  str = str:upper()
  for i = 1, #str do
    total = total * 26 + (str:byte(i) - 64)
  end
  return total
end

M.patterns = {
  -- Uppercase Roman Numerals (I, II, III, IV, V...)
  roman_upper = {
    to_symbol = function(index)
      return to_roman(index)
    end,
    to_index = function(symbol)
      return from_roman(symbol)
    end,
  },

  -- Lowercase Roman Numerals (i, ii, iii, iv, v...)
  roman_lower = {
    to_symbol = function(index)
      return to_roman(index):lower()
    end,
    to_index = function(symbol)
      return from_roman(symbol)
    end,
  },

  -- Uppercase Alphabet (A, B ... Z, AA, AB...)
  alpha_upper = {
    to_symbol = function(index)
      return to_alpha(index)
    end,
    to_index = function(symbol)
      return from_alpha(symbol)
    end,
  },

  -- Lowercase Alphabet (a, b ... z, aa, ab...)
  alpha_lower = {
    to_symbol = function(index)
      return to_alpha(index):lower()
    end,
    to_index = function(symbol)
      return from_alpha(symbol)
    end,
  },

  -- Decimal Numbers (1, 2, 3...)
  decimal = {
    to_symbol = function(index)
      return tostring(index)
    end,
    to_index = function(symbol)
      return tonumber(symbol) or 1
    end,
  },

  -- Hexadecimal Numbers (0x1, 0x2 ... 0xA...)
  hex = {
    to_symbol = function(index)
      return string.format('0x%X', index)
    end,
    to_index = function(symbol)
      return tonumber(symbol) or 1
    end,
  },

  -- Binary Numbers (0b1, 0b10, 0b11...)
  binary = {
    to_symbol = function(index)
      local bits = {}
      local n = index
      while n > 0 do
        table.insert(bits, 1, n % 2)
        n = math.floor(n / 2)
      end
      return '0b' .. (#bits > 0 and table.concat(bits, '') or '0')
    end,
    to_index = function(symbol)
      local clean = symbol:gsub('^0[bB]', '')
      return tonumber(clean, 2) or 1
    end,
  },
}

---@param symbol string
---@return string pattern_key
function M.detect_pattern(symbol)
  if symbol:match('^0[bB][01]+$') then
    return 'binary'
  end
  if symbol:match('^0[xX]%x+$') then
    return 'hex'
  end
  if symbol:match('^%d+$') then
    return 'decimal'
  end
  if symbol:match('^[IVXLCDM]+$') then
    return 'roman_upper'
  end
  if symbol:match('^[ivxlcdm]+$') then
    return 'roman_lower'
  end
  if symbol:match('^[A-Z]+$') then
    return 'alpha_upper'
  end
  if symbol:match('^[a-z]+$') then
    return 'alpha_lower'
  end
  return 'alpha_lower'
end

---@param symbol string
---@param offset? integer Step delta (default: 1)
---@return string new_symbol
function M.increment_symbol(symbol, offset)
  offset = offset or 1
  local key = M.detect_pattern(symbol)
  local pattern = M.patterns[key]

  local index = pattern.to_index(symbol)
  local new_index = math.max(1, index + offset)

  return pattern.to_symbol(new_index)
end

return M
