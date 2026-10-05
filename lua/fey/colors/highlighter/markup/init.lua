---@class FeyMarkupHighlighter
---@field highlighter FeyHighlighter
---@field private cache table
---@field private query vim.treesitter.Query
---@field private parsers { emphasis: FeyEmphasisHighlighter, link: FeyLinkHighlighter, latex: FeyLatexHighlighter }
local FeyMarkup = {}

---@param opts { highlighter: FeyHighlighter }
function FeyMarkup:new(opts)
  local data = {
    highlighter = opts.highlighter,
    cache = setmetatable({}, { __mode = 'k' }),
    query = vim.treesitter.query.get('fey', 'markup'),
  }
  setmetatable(data, self)
  self.__index = self
  data:_init_highlighters()
  return data
end

---@private
function FeyMarkup:_init_highlighters()
  self.parsers = {
    emphasis = require('fey.colors.highlighter.markup.emphasis'):new({ markup = self }),
    latex = require('fey.colors.highlighter.markup.latex'):new({ markup = self }),
  }
end

---@param bufnr number
---@param line number
---@param tree TSTree
---@param use_cache? boolean
function FeyMarkup:on_line(bufnr, line, tree, use_cache)
  local highlights = self:_get_highlights(bufnr, line, tree, use_cache)

  for type, highlight in pairs(highlights) do
    self.parsers[type]:highlight(highlight, bufnr)
  end
end

---@param bufnr number
---@param line number
---@param tree TSTree
---@param use_cache? boolean
---@return { emphasis: FeyMarkupHighlight[], link: FeyMarkupHighlight[], latex: FeyMarkupHighlight[], date: FeyMarkupHighlight[] }
function FeyMarkup:_get_highlights(bufnr, line, tree, use_cache)
  local line_content = vim.api.nvim_buf_get_lines(bufnr, line, line + 1, false)[1]

  if self.cache[bufnr] and self.cache[bufnr][line] and (use_cache or self.cache[bufnr][line].line_content == line_content) then
    return self.cache[bufnr][line].highlights
  end

  local result = self:get_node_highlights(tree:root(), bufnr, line)

  if not self.cache[bufnr] then self.cache[bufnr] = {} end

  self.cache[bufnr][line] = {
    line_content = line_content,
    highlights = result,
  }

  return result
end

---@param root_node TSNode
---@param source number | string
---@param line number
---@return { emphasis: FeyMarkupHighlight[], link: FeyMarkupHighlight[], latex: FeyMarkupHighlight[], date: FeyMarkupHighlight[] }
function FeyMarkup:get_node_highlights(root_node, source, line)
  local result = {
    emphasis = {},
    latex = {},
  }
  ---@type FeyMarkupNode[]
  local entries = {}

  for capture_id, node in self.query:iter_captures(root_node, source, line, line + 1) do
    local entry = nil
    for _, parser in pairs(self.parsers) do
      entry = parser:parse_node(node, self.query.captures[capture_id])
      if entry then
        table.insert(entries, entry)
        break
      end
    end
  end

  if #entries == 0 then return result end

  -- Open spans, keyed by the id their closer will seek.
  ---@type table<string, FeyMarkupNode>
  local seek = {}
  -- The open non-nestable span (code, verbatim, quote), if any. Its inside
  -- is literal: nothing may open or close there except its own closer.
  ---@type FeyMarkupNode?
  local literal = nil

  local is_valid_start_item = function(item)
    return self:has_valid_parent(item) and self.parsers[item.type]:is_valid_start_node(item, source)
  end

  local is_valid_end_item = function(item)
    return self:has_valid_parent(item) and self.parsers[item.type]:is_valid_end_node(item, source)
  end

  local push = function(item, from_range)
    table.insert(result[item.type], {
      id = item.id,
      char = item.char,
      from = from_range,
      to = item.range,
      metadata = item.metadata,
    })
  end

  -- A literal span opens only if its closer exists later on the line, so a
  -- stray backtick or apostrophe cannot switch off the rest of the line.
  local has_closer = function(index, item)
    for j = index + 1, #entries do
      local other = entries[j]
      if other.seek_id == item.id and is_valid_end_item(other) then return true end
    end
    return false
  end

  for index, item in ipairs(entries) do
    if literal and item.seek_id ~= literal.id then goto continue end

    if item.self_contained then
      if is_valid_end_item(item) then push(item, item.range) end
      goto continue
    end

    local from = seek[item.seek_id]

    -- Close the open span. A marker that cannot close it (`!a b!c d!`: the
    -- middle `!` has a letter after it) is ignored, so the span stays open
    -- for a later closer.
    if from then
      if is_valid_end_item(item) then
        push(item, from.range)
        seek[item.seek_id] = nil
        if literal == from then literal = nil end
        -- spans opened inside this one and never closed cannot cross its end
        for t, pos in pairs(seek) do
          if
            pos.range.line == from.range.line
            and pos.range.start_col > from.range.end_col
            and pos.range.start_col < item.range.start_col
          then
            seek[t] = nil
          end
        end
      end
      goto continue
    end

    if is_valid_start_item(item) then
      if item.nestable == false then
        if has_closer(index, item) then
          seek[item.id] = item
          literal = item
        end
      else
        seek[item.id] = item
      end
    end

    ::continue::
  end

  return result
end

---@param heading FeyHeading
---@return FeyMarkupPreparedHighlight[]
function FeyMarkup:get_prepared_heading_highlights(heading)
  local highlights = self:get_node_highlights(heading:node(), heading.file:get_source(), select(1, heading:node():range()))

  local result = {}

  for type, highlight in pairs(highlights) do
    vim.list_extend(result, self.parsers[type]:prepare_highlights(highlight))
  end

  vim.list_extend(result, self:_prepare_ts_highlights(heading))

  return result
end

---@private
---@param heading FeyHeading
---@return FeyMarkupPreparedHighlight[]
function FeyMarkup:_prepare_ts_highlights(heading)
  local heading_item_node = heading:node():field('title')[1]
  if not heading_item_node then return {} end
  local result = {}
  for node in heading_item_node:iter_children() do
    if node:type() == 'link' or node:type() == 'link_desc' then self:_prepare_link_higlight(heading, node, result) end
    if node:type() == 'timestamp' then self:_prepare_date_highlight(node, result) end
  end
  return result
end

---@param heading FeyHeading
---@param node TSNode
---@param result FeyMarkupPreparedHighlight[]
function FeyMarkup:_prepare_link_higlight(heading, node, result)
  local url = node:field('url')[1]
  local desc = node:field('desc')[1]
  local url_target = nil

  if desc then
    local sld, scd, _, ecd = desc:range()
    table.insert(result, {
      start_line = sld,
      start_col = scd,
      end_col = ecd,
      hl_group = '@fey.hyperlink.desc',
    })
    table.insert(result, {
      start_line = sld,
      start_col = scd - 2,
      end_col = scd,
      conceal = '',
    })
  end

  if url then
    local slu, scu, _, ecu = url:range()
    table.insert(result, {
      start_line = slu,
      start_col = scu,
      end_col = ecu,
      hl_group = '@fey.hyperlink.url',
      spell = false,
      conceal = desc and '' or nil,
    })
    url_target = heading.file:get_node_text(url)
  end
  local sl, sc, _, ec = node:range()
  table.insert(result, {
    start_line = sl,
    start_col = sc,
    end_col = ec,
    hl_group = '@fey.hyperlink',
    url = url_target,
  })
  table.insert(result, {
    start_line = sl,
    start_col = sc,
    end_col = sc + 2,
    conceal = '',
  })
  table.insert(result, {
    start_line = sl,
    start_col = ec - 2,
    end_col = ec,
    conceal = '',
  })
end

---@param node TSNode
---@param result FeyMarkupPreparedHighlight[]
function FeyMarkup:_prepare_date_highlight(node, result)
  local sl, sc, _, ec = node:range()
  table.insert(result, {
    start_line = sl,
    start_col = sc,
    end_col = ec,
    hl_group = node:child(0):type() == '<' and '@fey.timestamp.active' or '@fey.timestamp.inactive',
  })
end

function FeyMarkup:on_detach(bufnr) self.cache[bufnr] = nil end

---@param node TSNode
---@param source number | string
---@param offset_col_start? number
---@param offset_col_end? number
---@return string
function FeyMarkup:get_node_text(node, source, offset_col_start, offset_col_end)
  local range = { node:range() }
  return vim.treesitter.get_node_text(node, source, {
    metadata = {
      range = {
        range[1],
        math.max(0, range[2] + (offset_col_start or 0)),
        range[3],
        math.max(0, range[4] + (offset_col_end or 0)),
      },
    },
  })
end

function FeyMarkup:node_to_range(node)
  local start_row, start_col, _, end_col = node:range()
  return {
    line = start_row,
    start_col = start_col,
    end_col = end_col,
  }
end

-- Where running text lives in the fey grammar. Emphasis is only parsed there,
-- so fenced block contents, block names/parameters and tag heads stay plain.
--   paragraph   body text, list items, block-tag and pair-tag bodies
--   title       heading titles
--   contents    table cells (`cell`) and row-block cells (`cbi_cell`)
local TEXT_PARENTS = {
  paragraph = true,
  title = true,
}
local CELL_PARENTS = {
  cell = true,
  cbi_cell = true,
}

---@param item FeyMarkupNode
---@return boolean
function FeyMarkup:has_valid_parent(item)
  -- marker token -> expr -> the node holding the text
  local expr = item.node:parent()
  if not expr or expr:type() ~= 'expr' then return false end

  local parent = expr:parent()
  if not parent then return false end

  if TEXT_PARENTS[parent:type()] then return true end

  if parent:type() == 'contents' then
    local p = parent:parent()
    return p ~= nil and CELL_PARENTS[p:type()] == true
  end

  return false
end

function FeyMarkup:use_ephemeral()
  ---@diagnostic disable-next-line: invisible
  return self.highlighter._ephemeral
end

function FeyMarkup:get_links_for_line(bufnr, line)
  local cache = self.cache[bufnr]
  if not cache or not cache[line] then return end
  return cache[line].highlights.link
end

return FeyMarkup
