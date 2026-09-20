local M = {}
---@type table<string, vim.treesitter.Query>
local query_cache = {}

-- Reload treesitter highlighter without triggering FileType autocommands that include reloading entire file
function M.restart_highlights(bufnr)
  bufnr = bufnr or 0
  vim.treesitter.stop(bufnr)
  vim.treesitter.start(bufnr, 'fey')
end

function M.parse_current_file() return vim.treesitter.get_parser(0, 'fey', {}):parse() end

---@param opts? vim.treesitter.get_node.Opts
function M.get_node(opts)
  opts = opts or {}
  opts.lang = opts.lang or 'fey'
  return vim.treesitter.get_node(opts)
end

---@param cursor? table
---@return TSNode | nil
function M.get_node_at_cursor(cursor)
  M.parse_current_file()
  if not cursor then return M.get_node() end

  return M.get_node({
    bufnr = 0,
    pos = { cursor[1] - 1, cursor[2] },
  })
end

-- walks the tree to find a heading
function M.find_heading(node)
  if node:type() == 'heading' then return node end

  if node:type() == 'section' then
    -- The heading is always the first child of a section
    return node:field('heading')[1]
  end

  if node:parent() then return M.find_heading(node:parent()) end

  return nil
end

-- walks the tree to find a listitem
function M.find_item(node)
  if node:type() == 'listitem' then return node end

  if node:type() == 'list' then
    -- If there's a list then ther's a listitem
    return node:named_child(1)
  end

  if node:parent() then return M.find_item(node:parent()) end

  return nil
end

function M.find_list(node)
  if node:type() == 'list' then return node end

  if node:type() == 'listitem' then
    -- if there's a listitem then there's a list
    return node:parent()
  end

  if node:parent() then return M.find_list(node:parent()) end

  return nil
end

-- walks the tree to find an item or heading
---@param node TSNode | nil
---@param or_body boolean?
---@return TSNode | nil
function M.find_item_or_heading(node, or_body)
  if not node then return nil end

  local node_type = node:type()
  if or_body and node_type == 'document' then return node:field('body')[1] end
  if node_type == 'heading' or node_type == 'listitem' then return node end

  if node_type == 'list' then
    -- Move back one word to pick up the current listitem
    -- Move forward one word to pick up the current listitem

    vim.cmd([[norm w]])
    local back_node = M.find_item_or_heading(M.get_node_at_cursor(), or_body)
    if node:type() ~= 'listitem' then
      return node:named_child(0)
    else
      return back_node
    end
  end

  if node_type == 'section' then
    -- The heading is always the first child of a section
    return node:field('heading')[1]
  end
  return M.find_item_or_heading(node:parent(), or_body)
end

-- returns the nearest item or heading
function M.closest_item_or_heading_node(cursor) return M.find_item_or_heading(M.get_node_at_cursor(cursor)) end

-- returns the nearest item or heading or the root body of the document
function M.closest_item_heading_or_rootbody_node(cursor) return M.find_item_or_heading(M.get_node_at_cursor(cursor), true) end

-- returns the nearest heading
function M.closest_heading_node(cursor)
  local node = M.get_node_at_cursor(cursor)

  if not node then return nil end

  return M.find_heading(node)
end

-- returns nearest listitem
function M.closest_item_node(cursor)
  local node = M.get_node_at_cursor(cursor)

  if not node then return nil end

  return M.find_item(node)
end

-- returns nearest (sub)list
function M.closest_list_node(cursor)
  local node = M.get_node_at_cursor(cursor)

  if not node then return nil end

  return M.find_list(node)
end

-- returns nearest root list
---@return TSNode|nil, integer
function M.closest_root_list_node(cursor)
  local node = M.get_node_at_cursor(cursor)

  if not node then return nil, 0 end

  local list = M.find_list(node)
  local counter = 0
  while list do
    counter = counter + 1
    local parent = list:parent() and M.find_list(list:parent()) or nil
    if parent then
      list = parent
    else
      break
    end
  end

  return list, counter
end

---@param node TSNode | nil
---@param node_type string | string[]
---@return TSNode | nil
function M.closest_node(node, node_type)
  if not node then return nil end
  local types = type(node_type) == 'table' and node_type or { node_type }

  for _, t in ipairs(types) do
    if node:type() == t then return node end
  end

  return M.closest_node(node:parent(), types)
end

---@param node? TSNode
---@return TSNode[]
function M.get_named_children(node)
  local nodes = {}
  if not node then return nodes end
  for i = 0, node:named_child_count() - 1, 1 do
    nodes[i + 1] = node:named_child(i)
  end
  return nodes
end

---@return vim.treesitter.Query
function M.get_query(query)
  local ts_query = query_cache[query]
  if not ts_query then
    ts_query = vim.treesitter.query.parse('fey', query)
    query_cache[query] = ts_query
  end
  return ts_query
end

---@param node TSNode | nil
---@param type string
---@return TSNode | nil
function M.parents_until(node, type)
  local parent = node

  while parent do
    if parent:type() == type then return parent end
    parent = parent:parent()
  end
end

---@param node TSNode
---@param drawer string
---@param source? number|string
---@return boolean
function M.is_date_in_drawer(node, drawer, source)
  if
    (node:parent() and node:parent():type() == 'contents')
    and (node:parent():parent() and node:parent():parent():type() == 'drawer')
  then
    local drawer_node = node:parent():parent() --[[@as TSNode]]
    local drawer_name = vim.treesitter.get_node_text(drawer_node:field('name')[1], source or 0)
    return drawer_name:lower() == drawer
  end

  return false
end

function M.node_to_lsp_range(node)
  local start_line, start_col, end_line, end_col = vim.treesitter.get_node_range(node)
  local rtn = {}
  rtn.start = { line = start_line, character = start_col }
  rtn['end'] = { line = end_line, character = end_col }
  return rtn
end

---Return the range of the given node, but override the start column to be 0.
---This is needed when we want to parse the lines manually to ensure that
---we parse from the start of the line
---@param node TSNode
---@return number[]
function M.range_with_zero_start_col(node)
  local range = { node:range() }
  range[2] = 0
  return range
end

-- Memoizes a function based on the buffer tick of the provided bufnr.
-- The cache entry is cleared when the buffer is detached to avoid memory leaks.
-- The options argument is a table with one optional value:
--  - key: extracts the cache key from the given arguments.
---@param fn function the fn to memoize, taking the buffer as first argument
---@param options? {key: string|fun(...): string?} the memoization options
---@return function: a memoized function
function M.memoize_by_buf_tick(fn, options)
  options = options or {}

  ---@type table<string, {result: any, last_tick: integer}>
  local cache = setmetatable({}, { __mode = 'kv' })
  local key_fn = options.key or function(a) return a end

  return function(bufnr, ...)
    local key = key_fn(bufnr, ...) or ''
    local tick = vim.api.nvim_buf_get_changedtick(bufnr)

    if cache[key] then
      if cache[key].last_tick == tick then return cache[key].result end
    else
      local function detach_handler() cache[key] = nil end

      -- Clean up logic only!
      vim.api.nvim_buf_attach(bufnr, false, {
        on_detach = detach_handler,
        on_reload = detach_handler,
      })
    end

    cache[key] = {
      result = fn(bufnr, ...),
      last_tick = tick,
    }

    return cache[key].result
  end
end

return M
