local config = require('fey.config')

---@class FeyCompletionPlan:FeyCompletionSource
---@field completion FeyCompletion
---@field private pattern vim.regex
local FeyCompletionPlan = {}
FeyCompletionPlan.__index = FeyCompletionPlan

---@param opts { completion: FeyCompletion }
function FeyCompletionPlan:new(opts)
  local this = setmetatable({
    pattern = vim.regex([[\(^\s*\|\s\+\)\zs\w*$]]),
    completion = opts.completion,
  }, FeyCompletionPlan)
  return this
end

function FeyCompletionPlan:get_name()
  return 'plan'
end

---@param context FeyCompletionContext
---@return number | nil
function FeyCompletionPlan:get_start(context)
  local prev_line = vim.fn.getline(vim.fn.line('.') - 1)
  if not self.completion:is_heading_line(prev_line) or self.completion:is_heading_line(vim.fn.getline('.')) then
    return nil
  end

  return self.pattern:match_str(context.line)
end

---@return string[]
function FeyCompletionPlan:get_results(_)
  return {
    'DEADLINE:',
    'SCHEDULED:',
    'CLOSED:',
  }
end

return FeyCompletionPlan
