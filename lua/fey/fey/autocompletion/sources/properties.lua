---@class FeyCompletionProperties:FeyCompletionSource
---@field completion FeyCompletion
---@field private pattern vim.regex
local FeyCompletionProperties = {}
FeyCompletionProperties.__index = FeyCompletionProperties

---@param opts { completion: FeyCompletion }
function FeyCompletionProperties:new(opts)
  return setmetatable({
    completion = opts.completion,
    pattern = vim.regex([[^\s*\zs:\w*$]]),
  }, FeyCompletionProperties)
end

function FeyCompletionProperties:get_name()
  return 'properties'
end

---@param context FeyCompletionContext
---@return number | nil
function FeyCompletionProperties:get_start(context)
  if self.completion:is_heading_line(context.line) then
    return nil
  end

  return self.pattern:match_str(context.line)
end

---@return string[]
function FeyCompletionProperties:get_results(_)
  return {
    ':PROPERTIES:',
    ':END:',
    ':LOGBOOK:',
    ':STYLE:',
    ':REPEAT_TO_STATE:',
    ':CUSTOM_ID:',
    ':CATEGORY:',
  }
end

return FeyCompletionProperties
