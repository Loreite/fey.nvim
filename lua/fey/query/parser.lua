-- Parser for the query language (Dataview's DQL):
--
--   TABLE [WITHOUT ID] expr [AS "name"], ...      LIST [WITHOUT ID] [expr]
--   FROM <source>
--   WHERE expr | SORT expr [ASC|DESC], ... | GROUP BY expr [AS name]
--   FLATTEN expr [AS name] | LIMIT n
--
-- `parse` returns a plain AST; nothing here depends on the editor or the vault.
local M = {}

---@class FeyQueryToken
---@field type 'num'|'date'|'str'|'ident'|'tag'|'link'|'atype'|'op'|'eof'
---@field value any
---@field s integer first byte of the token in the source
---@field e integer last byte of the token

local COMMANDS = { from = true, where = true, sort = true, group = true, flatten = true, limit = true }
local TYPES = { table = true, list = true, task = true, calendar = true }

local ESCAPES = { n = '\n', t = '\t', r = '\r', ['"'] = '"', ["'"] = "'", ['\\'] = '\\' }

---@param msg string
---@param src string
---@param pos integer
local function fail(msg, src, pos)
  local line = select(2, src:sub(1, pos):gsub('\n', '')) + 1
  error(('query: %s (line %d)'):format(msg, line), 0)
end

---@param src string
---@return FeyQueryToken[]
local function lex(src)
  local tokens = {}
  local i, n = 1, #src
  local function push(type, value, s, e) tokens[#tokens + 1] = { type = type, value = value, s = s, e = e } end

  while i <= n do
    local c = src:sub(i, i)
    if c:match('%s') then
      i = i + 1
    elseif src:sub(i, i + 1) == '[[' then
      local close = src:find(']]', i + 2, true)
      if not close then fail('unterminated [[link]]', src, i) end
      push('link', src:sub(i + 2, close - 1), i, close + 1)
      i = close + 2
    elseif c == '"' or c == "'" then
      local out, j = {}, i + 1
      while true do
        local ch = src:sub(j, j)
        if ch == '' then fail('unterminated string', src, i) end
        if ch == c then break end
        if ch == '\\' then
          local nxt = src:sub(j + 1, j + 1)
          out[#out + 1] = ESCAPES[nxt] or ('\\' .. nxt)
          j = j + 2
        else
          out[#out + 1] = ch
          j = j + 1
        end
      end
      push('str', table.concat(out), i, j)
      i = j + 1
    elseif src:match('^%d%d%d%d%-%d%d%-%d%d', i) then
      -- date literal: 2026-10-20 or 2026-10-20T14:30[:00]
      local lit = src:match('^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:?%d*%.?%d*Z?', i) or src:match('^%d%d%d%d%-%d%d%-%d%d', i)
      push('date', lit, i, i + #lit - 1)
      i = i + #lit
    elseif c:match('%d') then
      local num = src:match('^%d+%.%d+', i) or src:match('^%d+', i)
      push('num', tonumber(num), i, i + #num - 1)
      i = i + #num
    elseif c == '#' then
      local tag = src:match('^#[^%s%(%)%[%]{},&|"\']+', i)
      if not tag then fail('stray #', src, i) end
      push('tag', tag:sub(2), i, i + #tag - 1)
      i = i + #tag
    elseif c == '@' then
      local at = src:match('^@[%w_%-]+', i)
      if not at then fail('stray @', src, i) end
      push('atype', at:sub(2):lower(), i, i + #at - 1)
      i = i + #at
    elseif c:match('[%a_]') or c:byte() >= 0x80 then
      -- identifiers may contain `-` and `/` like in Dataview: `due-date`, `a/b`
      local j = i
      while j <= n do
        local ch = src:sub(j, j)
        if ch:match('[%w_/%-]') or ch:byte() >= 0x80 then j = j + 1 else break end
      end
      push('ident', src:sub(i, j - 1), i, j - 1)
      i = j
    else
      local two = src:sub(i, i + 1)
      if two == '!=' or two == '<=' or two == '>=' or two == '==' or two == '=>' then
        push('op', two, i, i + 1)
        i = i + 2
      elseif c:match('[%+%-%*/%%=<>&|!%(%)%[%]{},%.:]') then
        push('op', c, i, i)
        i = i + 1
      else
        fail(('unexpected character %q'):format(c), src, i)
      end
    end
  end
  push('eof', nil, n + 1, n + 1)
  return tokens
end

---@class FeyQueryParser
---@field src string
---@field tokens FeyQueryToken[]
---@field pos integer
local Parser = {}
Parser.__index = Parser

---@return FeyQueryToken
function Parser:peek(offset) return self.tokens[math.min(self.pos + (offset or 0), #self.tokens)] end

---@return FeyQueryToken
function Parser:next()
  local t = self.tokens[self.pos]
  self.pos = math.min(self.pos + 1, #self.tokens)
  return t
end

---@param value string
function Parser:is_op(value, offset)
  local t = self:peek(offset)
  return t.type == 'op' and t.value == value
end

---@param word string lowercase keyword
function Parser:is_word(word, offset)
  local t = self:peek(offset)
  return t.type == 'ident' and t.value:lower() == word
end

function Parser:error(msg, tok)
  tok = tok or self:peek()
  fail(msg, self.src, tok.s)
end

function Parser:expect_op(value)
  if not self:is_op(value) then self:error(('expected %q'):format(value)) end
  return self:next()
end

function Parser:at_command()
  local t = self:peek()
  return t.type == 'eof' or (t.type == 'ident' and COMMANDS[t.value:lower()] == true)
end

-- Expressions -----------------------------------------------------------------

local BINARY = {
  ['|'] = { 1, 'or' }, ['or'] = { 1, 'or' },
  ['&'] = { 2, 'and' }, ['and'] = { 2, 'and' },
  ['='] = { 3, '=' }, ['=='] = { 3, '=' }, ['!='] = { 3, '!=' },
  ['<'] = { 3, '<' }, ['>'] = { 3, '>' }, ['<='] = { 3, '<=' }, ['>='] = { 3, '>=' },
  ['+'] = { 4, '+' }, ['-'] = { 4, '-' },
  ['*'] = { 5, '*' }, ['/'] = { 5, '/' }, ['%'] = { 5, '%' },
}

---@return table|nil op, integer|nil prec
function Parser:binary_op()
  local t = self:peek()
  local key
  if t.type == 'op' then
    key = t.value
  elseif t.type == 'ident' then
    key = t.value:lower()
    if key ~= 'and' and key ~= 'or' then return nil end
  else
    return nil
  end
  local info = BINARY[key]
  if not info then return nil end
  return info[2], info[1]
end

---@param min_prec? integer
---@return table
function Parser:expression(min_prec)
  min_prec = min_prec or 1
  local left = self:unary()
  while true do
    local op, prec = self:binary_op()
    if not op or prec < min_prec then break end
    self:next()
    local right = self:expression(prec + 1)
    left = { t = 'bin', op = op, l = left, r = right }
  end
  return left
end

function Parser:unary()
  local t = self:peek()
  if t.type == 'op' and (t.value == '!' or t.value == '-') then
    self:next()
    return { t = 'un', op = t.value, e = self:unary() }
  end
  if t.type == 'ident' and t.value:lower() == 'not' and not self:is_op('(', 1) then
    self:next()
    return { t = 'un', op = '!', e = self:unary() }
  end
  return self:postfix(self:primary())
end

---@return boolean
function Parser:lambda_ahead()
  -- `(a, b) =>`
  local depth, i = 0, 0
  while true do
    local t = self:peek(i)
    if t.type == 'eof' then return false end
    if t.type == 'op' then
      if t.value == '(' then depth = depth + 1 end
      if t.value == ')' then
        depth = depth - 1
        if depth == 0 then return self:is_op('=>', i + 1) end
      end
    end
    i = i + 1
  end
end

function Parser:primary()
  local t = self:next()
  if t.type == 'num' then return { t = 'num', v = t.value } end
  if t.type == 'str' then return { t = 'str', v = t.value } end
  if t.type == 'date' then return { t = 'date', v = t.value } end
  if t.type == 'link' then return { t = 'link', v = t.value } end
  if t.type == 'tag' then return { t = 'str', v = '#' .. t.value } end

  if t.type == 'ident' then
    local lower = t.value:lower()
    if lower == 'true' then return { t = 'bool', v = true } end
    if lower == 'false' then return { t = 'bool', v = false } end
    if lower == 'null' then return { t = 'null' } end
    if self:is_op('=>') then
      self:next()
      return { t = 'lambda', params = { t.value }, body = self:expression() }
    end
    if self:is_op('(') then
      self:next()
      local args = {}
      if not self:is_op(')') then
        repeat
          args[#args + 1] = self:expression()
        until not (self:is_op(',') and self:next())
      end
      self:expect_op(')')
      return { t = 'call', fn = lower, args = args, pos = t.s }
    end
    return { t = 'var', name = t.value }
  end

  if t.type == 'op' then
    if t.value == '(' then
      self.pos = self.pos - 1
      if self:lambda_ahead() then
        self:next()
        local params = {}
        if not self:is_op(')') then
          repeat
            local p = self:next()
            if p.type ~= 'ident' then self:error('expected parameter name', p) end
            params[#params + 1] = p.value
          until not (self:is_op(',') and self:next())
        end
        self:expect_op(')')
        self:expect_op('=>')
        return { t = 'lambda', params = params, body = self:expression() }
      end
      self:next()
      local e = self:expression()
      self:expect_op(')')
      return e
    end
    if t.value == '[' then
      local items = {}
      if not self:is_op(']') then
        repeat
          items[#items + 1] = self:expression()
        until not (self:is_op(',') and self:next())
      end
      self:expect_op(']')
      return { t = 'list', items = items }
    end
    if t.value == '{' then
      local pairs_ = {}
      if not self:is_op('}') then
        repeat
          local k = self:next()
          if k.type ~= 'ident' and k.type ~= 'str' then self:error('expected object key', k) end
          self:expect_op(':')
          pairs_[#pairs_ + 1] = { k = k.value, v = self:expression() }
        until not (self:is_op(',') and self:next())
      end
      self:expect_op('}')
      return { t = 'obj', pairs = pairs_ }
    end
  end
  self:error('unexpected ' .. (t.type == 'eof' and 'end of query' or ('%q'):format(tostring(t.value))), t)
end

function Parser:postfix(node)
  while true do
    if self:is_op('.') then
      self:next()
      local name = self:next()
      if name.type ~= 'ident' and name.type ~= 'num' then self:error('expected field name', name) end
      if name.type == 'ident' and self:is_op('(') then
        -- method call: `file.hasTag("x")` is `hastag(file, "x")`
        self:next()
        local args = {}
        if not self:is_op(')') then
          repeat
            args[#args + 1] = self:expression()
          until not (self:is_op(',') and self:next())
        end
        self:expect_op(')')
        node = { t = 'mcall', obj = node, fn = name.value:lower(), args = args, pos = name.s }
      else
        node = { t = 'field', obj = node, name = tostring(name.value) }
      end
    elseif self:is_op('[') then
      self:next()
      local idx = self:expression()
      self:expect_op(']')
      node = { t = 'index', obj = node, idx = idx }
    else
      return node
    end
  end
end

-- Sources -----------------------------------------------------------------------

function Parser:source_or()
  local left = self:source_and()
  while self:is_word('or') or self:is_op('|') do
    self:next()
    left = { t = 'or', l = left, r = self:source_and() }
  end
  return left
end

function Parser:source_and()
  local left = self:source_unary()
  while self:is_word('and') or self:is_op('&') do
    self:next()
    left = { t = 'and', l = left, r = self:source_unary() }
  end
  return left
end

function Parser:source_unary()
  if self:is_op('-') or self:is_op('!') then
    self:next()
    return { t = 'not', e = self:source_unary() }
  end
  return self:source_atom()
end

function Parser:source_atom()
  local t = self:peek()
  if t.type == 'tag' then
    self:next()
    return { t = 'label', v = t.value }
  end
  if t.type == 'str' then
    self:next()
    return { t = 'folder', v = t.value }
  end
  if t.type == 'link' then
    self:next()
    return { t = 'incoming', target = { t = 'link', v = t.value } }
  end
  if t.type == 'atype' then
    self:next()
    return { t = 'objects', v = t.value }
  end
  if self:is_op('(') then
    self:next()
    local e = self:source_or()
    self:expect_op(')')
    return e
  end
  if t.type == 'ident' and self:is_op('(', 1) then
    local name = t.value:lower()
    if name == 'csv' then self:error('csv() sources are not supported', t) end
    if name == 'outgoing' then
      self:next()
      self:next()
      local e = self:expression()
      self:expect_op(')')
      return { t = 'outgoing', target = e }
    end
    -- any other expression yielding a link: pages linking to it
    return { t = 'incoming', target = self:expression() }
  end
  if t.type == 'ident' then return { t = 'incoming', target = self:expression() } end
  self:error('expected a source (#label, "folder", [[link]] or outgoing(...))', t)
end

-- Query ---------------------------------------------------------------------------

---@param first FeyQueryToken
---@param last FeyQueryToken
function Parser:text(first, last) return self.src:sub(first.s, last.e) end

function Parser:parse_alias()
  if not self:is_word('as') then return nil end
  self:next()
  local t = self:next()
  if t.type ~= 'str' and t.type ~= 'ident' then self:error('expected a name after AS', t) end
  return tostring(t.value)
end

---@return table field { expr, alias, text }
function Parser:parse_field()
  local first = self:peek()
  local expr = self:expression()
  local last = self.tokens[self.pos - 1]
  return { expr = expr, text = self:text(first, last), alias = self:parse_alias() }
end

function Parser:parse_command()
  local word = self:next().value:lower()
  if word == 'from' then
    return { op = 'from', source = self:source_or() }
  elseif word == 'where' then
    return { op = 'where', expr = self:expression() }
  elseif word == 'sort' then
    local keys = {}
    repeat
      local key = { expr = self:expression(), desc = false }
      if self:is_word('desc') or self:is_word('descending') then
        key.desc = true
        self:next()
      elseif self:is_word('asc') or self:is_word('ascending') then
        self:next()
      end
      keys[#keys + 1] = key
    until not (self:is_op(',') and self:next())
    return { op = 'sort', keys = keys }
  elseif word == 'group' then
    if not self:is_word('by') then self:error('expected BY after GROUP') end
    self:next()
    local first = self:peek()
    local expr = self:expression()
    local text = self:text(first, self.tokens[self.pos - 1])
    return { op = 'group', expr = expr, alias = self:parse_alias(), text = text }
  elseif word == 'flatten' then
    local first = self:peek()
    local expr = self:expression()
    local text = self:text(first, self.tokens[self.pos - 1])
    return { op = 'flatten', expr = expr, alias = self:parse_alias(), text = text }
  else
    return { op = 'limit', expr = self:expression() }
  end
end

---@class FeyQueryAst
---@field type 'table'|'list'|'task'|'calendar'
---@field without_id boolean
---@field fields { expr: table, alias?: string, text: string }[]
---@field commands table[]

---@param src string
---@return FeyQueryAst
function M.parse(src)
  local p = setmetatable({ src = src, tokens = lex(src), pos = 1 }, Parser)
  local head = p:next()
  if head.type ~= 'ident' or not TYPES[head.value:lower()] then
    p:error('a query starts with TABLE, LIST, TASK or CALENDAR', head)
  end
  local ast = { type = head.value:lower(), without_id = false, fields = {}, commands = {} }

  if p:is_word('without') and p:is_word('id', 1) then
    p:next()
    p:next()
    ast.without_id = true
  end

  if not p:at_command() then
    repeat
      ast.fields[#ast.fields + 1] = p:parse_field()
    until not (p:is_op(',') and p:next())
  end
  if ast.type == 'list' and #ast.fields > 1 then p:error('LIST takes at most one expression') end

  while p:peek().type ~= 'eof' do
    if not p:at_command() then p:error(('unexpected %q'):format(tostring(p:peek().value))) end
    ast.commands[#ast.commands + 1] = p:parse_command()
  end
  return ast
end

---Parse a stand alone expression (used by tests and callers that evaluate expressions)
---@param src string
---@return table
function M.parse_expression(src)
  local p = setmetatable({ src = src, tokens = lex(src), pos = 1 }, Parser)
  local e = p:expression()
  if p:peek().type ~= 'eof' then p:error('unexpected trailing input') end
  return e
end

return M
