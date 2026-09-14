---@class FeyCompletionDirectives:FeyCompletionSource
---@field private pattern vim.regex
local FeyCompletionDirectives = {}
FeyCompletionDirectives.__index = FeyCompletionDirectives

function FeyCompletionDirectives:new()
  return setmetatable({
    pattern = vim.regex([[^\s*\zs\#+\?\w*$]]),
  }, FeyCompletionDirectives)
end

---@param context FeyCompletionContext
---@return number | nil
function FeyCompletionDirectives:get_start(context)
  return self.pattern:match_str(context.line)
end

function FeyCompletionDirectives:get_name()
  return 'directives'
end

---@return string[]
function FeyCompletionDirectives:get_results(_)
  return {
    '#+title',
    '#+author',
    '#+email',
    '#+name',
    '#+filetags',
    '#+archive',
    '#+options',
    '#+category',
    '#+begin_src',
    '#+begin_example',
    '#+end_src',
    '#+end_example',
  }
end

return FeyCompletionDirectives
