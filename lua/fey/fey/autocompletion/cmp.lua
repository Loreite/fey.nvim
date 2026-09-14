local has_cmp, cmp = pcall(require, 'cmp')
if not has_cmp then
  return
end

local fey = require('fey')

local Source = {}

Source.new = function()
  local self = setmetatable({}, { __index = Source })
  return self
end

Source.get_debug_name = function()
  return 'fey'
end

function Source:is_available()
  return vim.bo.filetype == 'fey'
end

function Source:get_trigger_characters(_)
  return { '#', '+', ':', '*', '.', '/' }
end

function Source:complete(params, callback)
  local offset = fey.completion:get_start({ line = params.context.cursor_before_line }) + 1
  local base = string.sub(params.context.cursor_before_line, offset)
  local results = fey.completion:complete({
    line = params.context.cursor_before_line,
    base = base,
    fuzzy = true,
  })
  local items = {}
  for _, item in ipairs(results) do
    table.insert(items, {
      label = item.word,
      labelDetails = {
        description = item.menu,
      },
    })
  end

  callback({
    items = items,
    isIncomplete = true,
  })
end

cmp.register_source('fey', Source.new())
