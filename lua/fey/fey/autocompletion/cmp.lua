local has_cmp, cmp = pcall(require, 'cmp')
if not has_cmp then return end

local fey = require('fey')

local Source = {}

Source.new = function() return setmetatable({}, { __index = Source }) end

Source.get_debug_name = function() return 'fey' end

function Source:is_available() return vim.bo.filetype == 'fey' end

-- the delimiters of a tag head and the openers of a tag
function Source:get_trigger_characters(_) return { ',', ';', ':', ' ', '@', '#', '[', '/' } end

function Source:complete(params, callback)
  local line = params.context.cursor_before_line
  local start = fey.completion:get_start({ line = line })
  if start < 0 then return callback({ items = {}, isIncomplete = false }) end
  local results = fey.completion:complete({ line = line, base = string.sub(line, start + 1), fuzzy = true })
  local row = params.context.cursor.row - 1
  local items = {}
  for _, item in ipairs(results) do
    table.insert(items, {
      label = item.word,
      labelDetails = { description = item.menu },
      textEdit = {
        newText = item.word,
        range = { start = { line = row, character = start }, ['end'] = { line = row, character = #line } },
      },
    })
  end
  callback({ items = items, isIncomplete = true })
end

cmp.register_source('fey', Source.new())
