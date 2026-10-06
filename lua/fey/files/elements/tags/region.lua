-- The metadata region of a heading, as tree-sitter nodes (see `edit.lua` for what it is). Pure: it
-- needs no buffer and no config, so the vault can use it on any parsed text.
local M = {}

---A line tag that carries text after its head is content, not metadata
---@param node TSNode
---@return boolean
local function is_meta_node(node)
  local t = node:type()
  if t == 'scope_tag' then return true end
  if t ~= 'line_tag' then return false end
  for child in node:iter_children() do
    if child:type() == 'body' then return false end
  end
  return true
end

---@param node TSNode
---@return integer row last row (0-based) the node covers
local function end_row(node)
  local er, ec = node:end_()
  return ec == 0 and er - 1 or er
end

---@class FeyRegionEntry
---@field node TSNode a scope or line tag
---@field region 'title'|'body'

---The tags of the metadata region of a section, in document order: the tags in the title of its
---heading, then the leading lines of its body that hold nothing but tags. A paragraph spans lines, so
---the body is judged per line inside it: a tag that shares its line with text is content and ends the
---region.
---@param section TSNode a `section`
---@return FeyRegionEntry[] entries
---@return integer|nil last_row 0-based last line of the body part of the region
function M.entries(section)
  local out, last_row = {}, nil
  local head = section:field('heading')[1]
  local title = head and head:field('title')[1]
  if title then
    for child in title:iter_children() do
      local t = child:type()
      if (t == 'scope_tag' or t == 'line_tag') and not child:has_error() then
        table.insert(out, { node = child, region = 'title' })
      end
    end
  end

  local body = section:field('body')[1]
  if not body then return out, last_row end

  local stopped = false
  for child in body:iter_children() do
    if stopped then break end
    if child:named() then
      local t = child:type()
      if t == 'scope_tag' then
        table.insert(out, { node = child, region = 'body' })
        last_row = end_row(child)
      elseif t == 'paragraph' then
        local pending = {}
        local function commit(before_row)
          for _, node in ipairs(pending) do
            if not before_row or end_row(node) < before_row then
              table.insert(out, { node = node, region = 'body' })
              last_row = end_row(node)
            end
          end
          pending = {}
        end
        for c in child:iter_children() do
          if c:named() then
            if is_meta_node(c) then
              table.insert(pending, c)
            else
              commit((c:start()))
              stopped = true
              break
            end
          end
        end
        if not stopped then commit() end
      else
        stopped = true
      end
    end
  end
  return out, last_row
end

---Text of the title of a heading without its metadata tags: scope and line tags whose name is in `meta`
---are dropped, and the blanks after a dropped tag go with it. A title without such a tag is returned as
---it is, trimmed.
---@param title_node TSNode
---@param source integer|string buffer number or the text the node was parsed from
---@param meta table<string, boolean> names of the metadata tags
---@return string
function M.title_text(title_node, source, meta)
  local text = vim.treesitter.get_node_text(title_node, source)
  local _, _, base = title_node:start()
  local parts, pos, dropped = {}, 0, false
  for child in title_node:iter_children() do
    local t = child:type()
    if t == 'scope_tag' or t == 'line_tag' then
      local name = child:field('name')[1]
      if name and meta[vim.treesitter.get_node_text(name, source)] then
        local _, _, from = child:start()
        local _, _, to = child:end_()
        table.insert(parts, text:sub(pos + 1, from - base))
        pos = to - base
        while text:sub(pos + 1, pos + 1):match('[ \t]') do pos = pos + 1 end
        dropped = true
      end
    end
  end
  table.insert(parts, text:sub(pos + 1))
  return vim.trim(dropped and table.concat(parts) or text)
end

return M
