local config = require('fey.config')

---@class FeyCompletionTodoKeywords:FeyCompletionSource
---@field private pattern vim.regex
local FeyCompletionTodoKeywords = {}
FeyCompletionTodoKeywords.__index = FeyCompletionTodoKeywords

function FeyCompletionTodoKeywords:new()
  local this = setmetatable({
    pattern = vim.regex([[^\*\+\s\+\zs\w*$]]),
  }, FeyCompletionTodoKeywords)
  return this
end

function FeyCompletionTodoKeywords:get_name()
  return 'todo_keywords'
end

---@param context FeyCompletionContext
---@return number | nil
function FeyCompletionTodoKeywords:get_start(context)
  return self.pattern:match_str(context.line)
end

---@return string[]
function FeyCompletionTodoKeywords:get_results(_)
  return config:get_todo_keywords():all_values()
end

return FeyCompletionTodoKeywords
