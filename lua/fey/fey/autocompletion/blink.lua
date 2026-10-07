local fey = require('fey')

local Source = {}

Source.new = function() return setmetatable({}, { __index = Source }) end

function Source:enabled() return vim.bo.filetype == 'fey' end

-- the delimiters of a tag head and the openers of a tag
function Source:get_trigger_characters(_) return { ',', ';', ':', ' ', '@', '#', '[', '/' } end

function Source:get_completions(ctx, callback)
  local line = ctx.line:sub(1, ctx.cursor[2])
  local start = fey.completion:get_start({ line = line })
  local items = {}
  if start >= 0 then
    local results = fey.completion:complete({ line = line, base = string.sub(line, start + 1), fuzzy = true })
    local row = ctx.cursor[1] - 1
    for _, item in ipairs(results) do
      table.insert(items, {
        label = item.word,
        labelDetails = item.menu and { description = item.menu } or nil,
        textEdit = {
          newText = item.word,
          range = { start = { line = row, character = start }, ['end'] = { line = row, character = #line } },
        },
      })
    end
  end
  callback({ context = ctx, is_incomplete_forward = true, is_incomplete_backward = true, items = items })
  return function() end
end

return Source
