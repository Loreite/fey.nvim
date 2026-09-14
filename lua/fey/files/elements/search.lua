--TODO: Support regex search

local Date = require('fey.objects.date')

---@class FeySearch
---@field term string
---@field expressions table
---@field or_items FeyOrItem[]
---@field todo_search? FeyTodoMatch
local Search = {}

---@class FeySearchable
---@field props table<string, string>
---@field tags string|string[]
---@field todo string

---@class FeyOrItem
---@field and_items FeyAndItem[]
local OrItem = {}
OrItem.__index = OrItem

---@class FeyAndItem
---@field contains FeyMatchable[]
---@field excludes FeyMatchable[]
local AndItem = {}
AndItem.__index = AndItem

---@alias FeyMatchable FeyTagMatch|FeyPropertyMatch

---@class FeyTagMatch
---@field value string
local TagMatch = {}
TagMatch.__index = TagMatch

---@alias FeyPropertyMatch FeyPropertyDateMatch|FeyPropertyStringMatch|FeyPropertyNumberMatch
local PropertyMatch = {}
PropertyMatch.__index = PropertyMatch

---@alias FeyPropertyMatchOperator '='|'<>'|'<'|'<='|'>'|'>='

---@class FeyPropertyDateMatch
---@field name string
---@field operator FeyPropertyMatchOperator
---@field value FeyDate
local PropertyDateMatch = {}
PropertyDateMatch.__index = PropertyDateMatch

---@class FeyPropertyStringMatch
---@field name string
---@field operator FeyPropertyMatchOperator
---@field value string
local PropertyStringMatch = {}
PropertyStringMatch.__index = PropertyStringMatch

---@class FeyPropertyNumberMatch
---@field name string
---@field operator FeyPropertyMatchOperator
---@field value number
local PropertyNumberMatch = {}
PropertyNumberMatch.__index = PropertyNumberMatch

---@class FeyTodoMatchAndItem
---@field operator string
---@field value string

---@class FeyTodoMatch
---@field orItems FeyTodoMatchAndItem[][]
local TodoMatch = {}
TodoMatch.__index = TodoMatch

---@type table<FeyPropertyMatchOperator, fun(a: string|number|FeyDate, b: string|number|FeyDate): boolean>
local OPERATORS = {
  ['='] = function(a, b)
    local result = a == b
    return result
  end,
  ['<='] = function(a, b)
    return a <= b
  end,
  ['<'] = function(a, b)
    return a < b
  end,
  ['>='] = function(a, b)
    return a >= b
  end,
  ['>'] = function(a, b)
    return a > b
  end,
  ['<>'] = function(a, b)
    return a ~= b
  end,
}

---Parses a pattern from the beginning of an input using Lua's pattern syntax
---@param input string
---@param pattern string
---@return string?, string
local function parse_pattern(input, pattern)
  local value = input:match('^' .. pattern)
  if value then
    return value, input:sub(#value + 1)
  else
    return nil, input
  end
end

---Parses the first of a sequence of patterns
---@param input string The input to parse
---@param ... string The patterns to accept
---@return string?, string
local function parse_pattern_choice(input, ...)
  for _, pattern in ipairs({ ... }) do
    local value, remaining = parse_pattern(input, pattern)
    if value then
      return value, remaining
    end
  end

  return nil, input
end

---@generic T
---@param input string
---@param item_parser fun(input: string): (T?, string)
---@param delimiter_pattern string
---@return (T[])?, string
local function parse_delimited_sequence(input, item_parser, delimiter_pattern)
  local sequence, item, delimiter = {}, nil, nil
  local original_input = input

  -- Parse the first item
  item, input = item_parser(input)
  if not item then
    return sequence, input
  end
  table.insert(sequence, item)

  -- Continue parsing items while there's a trailing delimiter
  delimiter, input = parse_pattern(input, delimiter_pattern)
  while delimiter do
    item, input = item_parser(input)
    if not item then
      return nil, original_input
    end

    table.insert(sequence, item)

    delimiter, input = parse_pattern(input, delimiter_pattern)
  end

  return sequence, input
end

---@param term string
---@return FeySearch
function Search:new(term)
  ---@type FeySearch
  local data = {
    term = term,
    expressions = {},
    or_items = {},
    todo_search = nil,
  }
  setmetatable(data, self)
  self.__index = self
  data:_parse()

  return data
end

---@param item FeySearchable
---@return boolean
function Search:check(item)
  local ors_match = false
  for _, or_item in ipairs(self.or_items) do
    if or_item:match(item) then
      ors_match = true
      break
    end
  end

  local todos_match
  if self.todo_search then
    todos_match = self.todo_search:match(item)
  else
    todos_match = true
  end

  return ors_match and todos_match
end

---@private
function Search:_parse()
  local input = self.term
  -- Parse the sequence of ORs
  self.or_items, input = parse_delimited_sequence(input, function(i)
    return OrItem:parse(i)
  end, '%|')

  -- If the sequence failed to parse, reset the array
  self.or_items = self.or_items or {}

  -- Parse the TODO word filters if present
  self.todo_search, input = TodoMatch:parse(input)
end

---@private
---@return FeyOrItem
function OrItem:_new()
  ---@type FeyOrItem
  local or_item = {
    and_items = {},
  }

  setmetatable(or_item, OrItem)
  return or_item
end

---@param input string
---@return FeyOrItem?, string
function OrItem:parse(input)
  ---@type FeyAndItem[]?
  local and_items
  local original_input = input

  and_items, input = parse_delimited_sequence(input, function(i)
    return AndItem:parse(i)
  end, '%&')

  if not and_items then
    return nil, original_input
  end

  local or_item = OrItem:_new()
  or_item.and_items = and_items

  return or_item, input
end

---Verifies that each AndItem contained within the OrItem matches
---@param item FeySearchable
---@return boolean
function OrItem:match(item)
  for _, and_item in ipairs(self.and_items) do
    if not and_item:match(item) then
      return false
    end
  end

  return true
end

---@private
---@return FeyAndItem
function AndItem:_new()
  ---@type FeyAndItem
  local and_item = {
    contains = {},
    excludes = {},
  }

  setmetatable(and_item, AndItem)
  return and_item
end

---@param input string
---@return FeyAndItem?, string
function AndItem:parse(input)
  ---@type FeyAndItem
  local and_item = AndItem:_new()
  ---@type string?
  local operator
  local original_input = input

  operator, input = parse_pattern(input, '[%+%-]?')

  -- A '+' operator is implied if none is present
  if operator == '' then
    operator = '+'
  end

  while operator do
    ---@type FeyMatchable?
    local matchable

    -- Try to parse as a PropertyMatch first
    matchable, input = PropertyMatch:parse(input)

    -- If it wasn't a property match, then try a tag match
    if not matchable then
      matchable, input = TagMatch:parse(input)
      if not matchable then
        return nil, original_input
      end
    end

    if operator == '+' then
      table.insert(and_item.contains, matchable)
    elseif operator == '-' then
      table.insert(and_item.excludes, matchable)
    else
      -- This should never happen if I wrote the operator pattern correctly
    end

    -- Attempt to parse the next operator
    operator, input = parse_pattern(input, '[%+%-]')
  end

  return and_item, input
end

---@param item FeySearchable
---@return boolean
function AndItem:match(item)
  for _, c in ipairs(self.contains) do
    if not c:match(item) then
      return false
    end
  end

  for _, e in ipairs(self.excludes) do
    if e:match(item) then
      return false
    end
  end

  return true
end

---@private
---@param tag string
---@return FeyTagMatch
function TagMatch:_new(tag)
  ---@type FeyTagMatch
  local tag_match = { value = tag }
  setmetatable(tag_match, TagMatch)

  return tag_match
end

---@param input string
---@return FeyTagMatch?, string
function TagMatch:parse(input)
  local tag
  tag, input = parse_pattern(input, '[\128-\255%w_%%@#]+')
  if not tag then
    return nil, input
  end

  return TagMatch:_new(tag), input
end

---@param item FeySearchable
---@return boolean
function TagMatch:match(item)
  local item_tags = item.tags
  if type(item_tags) == 'string' then
    return item_tags == self.value
  end

  for _, tag in ipairs(item_tags) do
    if tag == self.value then
      return true
    end
  end

  return false
end

---@param input string
---@return FeyPropertyMatch?, string
function PropertyMatch:parse(input)
  ---@type string?, FeyPropertyMatchOperator?
  local name, operator, string_str, number_str, date_str
  local original_input = input

  name, input = parse_pattern(input, '([^%-%+=<>&]+)[=<>]+')
  if not name then
    return nil, original_input
  end
  name = name:lower()

  operator, input = self:_parse_operator(input)
  if not operator then
    return nil, original_input
  end

  -- Number property
  number_str, input = parse_pattern(input, '%d+')
  if number_str then
    local number = tonumber(number_str) --[[@as number]]
    return PropertyNumberMatch:new(name, operator, number), input
  end

  -- Date property
  date_str, input = parse_pattern(input, '"<[^>]+>"')
  if date_str then
    date_str = date_str:sub(2, -2)
    ---@type string?, FeyDate?
    local date_content, date_value
    if date_str == '<today>' then
      date_value = Date.today()
    elseif date_str == '<tomorrow>' then
      date_value = Date.tomorrow()
    else
      -- Parse relative formats (e.g. <+1d>) as well as absolute
      date_content = date_str:match('^<([%+%-]%d+[dmyhwM])>$')
      if date_content then
        date_value = Date.today()
        date_value = date_value:adjust(date_content)
      else
        date_content = date_str:match('^<([^>]+)>$')
        if date_content then
          date_value = Date.from_string(date_content)
        end
      end
    end

    ---@type FeyDate?
    if date_value then
      return PropertyDateMatch:new(name, operator, date_value), input
    else
      -- It could be a string query so reset the parse input
      input = date_str .. input
    end
  end

  -- String property
  string_str, input = parse_pattern(input, '"[^"]+"')
  if string_str then
    ---@type string
    local unquote_string = string_str:match('^"([^"]+)"$')
    return PropertyStringMatch:new(name, operator, unquote_string), input
  end

  return nil, original_input
end

---@private
---Parses one of the comparison operators (=, <>, <, <=, >, >=)
---@param input string
---@return FeyPropertyMatchOperator, string
function PropertyMatch:_parse_operator(input)
  return parse_pattern_choice(input, '%=', '%<%>', '%<%=', '%<', '%>%=', '%>') --[[@as FeyPropertyMatchOperator]]
end

---Constructs a PropertyNumberMatch
---@param name string
---@param operator FeyPropertyMatchOperator
---@param value number
---@return FeyPropertyNumberMatch
function PropertyNumberMatch:new(name, operator, value)
  ---@type FeyPropertyNumberMatch
  local number_match = {
    name = name,
    operator = operator,
    value = value,
  }

  setmetatable(number_match, PropertyNumberMatch)

  return number_match
end

---@param item FeySearchable
---@return boolean
function PropertyNumberMatch:match(item)
  local item_str_value = item.props[self.name]

  -- If the property in question is not a number, it's not a match
  local item_num_value = tonumber(item_str_value)
  if not item_num_value then
    return false
  end

  return OPERATORS[self.operator](item_num_value, self.value)
end

---@param name string
---@param operator FeyPropertyMatchOperator
---@param value FeyDate
---@return FeyPropertyDateMatch
function PropertyDateMatch:new(name, operator, value)
  ---@type FeyPropertyDateMatch
  local date_match = {
    name = name,
    operator = operator,
    value = value,
  }

  setmetatable(date_match, PropertyDateMatch)
  return date_match
end

---@param item FeySearchable
---@return boolean
function PropertyDateMatch:match(item)
  local item_value = item.props[self.name]

  -- If the property is missing, then it's not a match
  if not item_value then
    return false
  end

  -- Extract the content between the braces/brackets
  local date_content = item_value:match('^[<%[]([^>%]]+)[>%]]$')
  if not date_content then
    return false
  end

  ---@type FeyDate?
  local item_date = Date.from_string(date_content)
  if not item_date then
    return false
  end

  return OPERATORS[self.operator](item_date, self.value)
end

---@param name string
---@param operator FeyPropertyMatchOperator
---@param value string
---@return FeyPropertyStringMatch
function PropertyStringMatch:new(name, operator, value)
  ---@type FeyPropertyStringMatch
  local string_match = {
    name = name,
    operator = operator,
    value = value,
  }

  setmetatable(string_match, PropertyStringMatch)

  return string_match
end

---@param item FeySearchable
---@return boolean
function PropertyStringMatch:match(item)
  local item_value = item.props[self.name] or ''
  return OPERATORS[self.operator](item_value, self.value)
end

---@private
---@return FeyTodoMatch
function TodoMatch:_new()
  local todo_match = {
    orItems = {},
  }

  setmetatable(todo_match, TodoMatch)

  return todo_match
end

---@param input string
---@return FeyTodoMatch?, string
function TodoMatch:parse(input)
  local original_input = input

  -- Parse the '/' or '/!' prefix that indicates a TodoMatch
  ---@type string?
  local prefix
  prefix, input = parse_pattern(input, '%/[%!]?')
  if not prefix then
    return nil, original_input
  end

  -- Parse a whitelist of keywords
  --- @type string[]?
  local orItems
  orItems, input = parse_delimited_sequence(input, function(i)
    ---@type string?
    local operator
    operator, i = parse_pattern(i, '[%+%-]?')

    if operator == '' then
      operator = '+'
    end

    local andItems = {}

    while operator do
      ---@type string?
      local value
      value, i = parse_pattern(i, '%w+')
      if not value then
        break
      end
      table.insert(andItems, {
        operator = operator,
        value = value,
      })

      operator, i = parse_pattern(i, '[%+%-]')
    end

    return andItems, i
  end, '%|')

  if not orItems or #orItems == 0 then
    return nil, original_input
  end

  local todo_match = TodoMatch:_new()
  todo_match.orItems = orItems
  return todo_match, input
end

---@param item FeySearchable
---@return boolean
function TodoMatch:match(item)
  local item_todo = item.todo

  for _, orItem in ipairs(self.orItems) do
    local validItems = true
    for _, andItem in ipairs(orItem) do
      if andItem.operator == '-' and item_todo == andItem.value then
        validItems = false
        break
      elseif andItem.operator == '+' and item_todo ~= andItem.value then
        validItems = false
        break
      end
    end

    if validItems then
      return true
    end
  end

  return false
end

return Search
