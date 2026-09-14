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
  local offset = fey.completion:get_start({ line = line }) + 1
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

FeyLspHandlers[methods.textDocument_references] = function(params)
  local fey = require('fey')
  local heading =
    fey.files:get(vim.uri_to_fname(params.textDocument.uri)):get_closest_heading({ params.position.line + 1, 0 })
  local custom_id = heading:get_property('CUSTOM_ID', false)
  local title = heading:get_title()

  if not heading then
    return {}
  end

  local function is_valid_target(target)
    if target == '*' .. title or target == title then
      return true
    end

    if custom_id and target == '#' .. custom_id then
      return true
    end

    return false
  end

  ---@type lsp.Location[]
  local locations = {}

  for _, feyfile in ipairs(fey.files:all()) do
    for _, link in ipairs(feyfile:get_links()) do
      local file_path = link.url:get_file_path()
      local target_or_path = link.url:get_target() or link.url:get_path()
      local target = link.url:get_target()

      local location = {
        uri = vim.uri_from_fname(feyfile.filename),
        range = link.range:to_lsp(),
      }

      -- is a file heading link
      if file_path and vim.fs.normalize(file_path) == vim.fs.normalize(heading.file.filename) then
        if not target or is_valid_target(target) then
          table.insert(locations, location)
        end
        goto continue
      end

      -- is local link
      if feyfile.filename == heading.file.filename and is_valid_target(target_or_path) then
        table.insert(locations, location)
      end

      ::continue::
    end
  end

  return locations
end

return FeyLspHandlers
