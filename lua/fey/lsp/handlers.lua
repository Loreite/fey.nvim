local methods = vim.lsp.protocol.Methods
local FeyLspHandlers = {}

local HEADLINE_KIND = vim.lsp.protocol.SymbolKind.Struct

---@param heading FeyHeading
local function get_heading_symbol(heading)
  ---@cast heading FeyHeading
  local range = heading:get_range():to_lsp()
  local result = {
    name = heading:get_title(),
    kind = HEADLINE_KIND,
    range = range,
    selectionRange = range,
  }
  local child_headings = heading:get_child_headings()
  if #child_headings > 0 then
    result.children = vim.tbl_map(get_heading_symbol, child_headings)
  end
  return result
end

FeyLspHandlers[methods.textDocument_documentSymbol] = function(params)
  local filename = vim.uri_to_fname(params.textDocument.uri)
  local feyfile = require('fey').files:load_file_sync(filename)
  if not feyfile then
    return {}
  end

  return vim.tbl_map(get_heading_symbol, feyfile:get_top_level_headings())
end

FeyLspHandlers[methods.workspace_symbol] = function(params)
  local results = {}
  local headings = require('fey').files:find_headings_matching_search_term(params.query or '', false, false)
  for _, heading in pairs(headings) do
    table.insert(results, {
      name = heading:get_title(),
      kind = HEADLINE_KIND,
      location = {
        uri = vim.uri_from_fname(heading.file.filename),
        range = heading:get_range():to_lsp(),
      },
    })
  end

  return results
end

FeyLspHandlers[methods.textDocument_completion] = function(params)
  local line = vim.api
    .nvim_buf_get_lines(vim.uri_to_bufnr(params.textDocument.uri), params.position.line, params.position.line + 1, false)[1]
    :sub(1, params.position.character)

  local fey = require('fey')
  local start = fey.completion:get_start({ line = line })
  if start < 0 then return { isIncomplete = false, items = {} } end
  local offset = start + 1
  local base = string.sub(line, offset)

  local completion = fey.completion:complete({
    line = line,
    base = base,
    fuzzy = true,
  })

  local results = vim.tbl_map(function(item)
    return {
      label = item.word,
      labelDetails = item.menu and { description = item.menu } or nil,
      textEdit = {
        newText = item.word,
        range = {
          start = { line = params.position.line, character = offset - 1 },
          ['end'] = { line = params.position.line, character = params.position.character },
        },
      },
    }
  end, completion)

  return {
    isIncomplete = true,
    items = results,
  }
end

---The links and section tags that lead to the heading at the position (or to the file, above the first heading),
---found in the index of the hollow
FeyLspHandlers[methods.textDocument_references] = function(params)
  local path = vim.uri_to_fname(params.textDocument.uri)
  local vault = require('fey.vault').for_path(path)
  if not vault then return {} end
  local rel = vault:rel_of(path)
  if not rel then return {} end
  local signature
  for _, h in ipairs(vault:headings(rel)) do
    if h.line <= params.position.line + 1 and (h.end_line or h.line) >= params.position.line + 1 then signature = h.signature end
  end
  local locations = {}
  for _, row in ipairs(vault:backlinks(rel, signature)) do
    local line = row.line - 1
    table.insert(locations, {
      uri = vim.uri_from_fname(vault:abs(row.path)),
      range = { start = { line = line, character = 0 }, ['end'] = { line = line, character = 0 } },
    })
  end
  return locations
end

return FeyLspHandlers
