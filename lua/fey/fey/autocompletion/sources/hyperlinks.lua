---@class FeyCompletionHyperlinks:FeyCompletionSource
---@field completion FeyCompletion
---@field private pattern vim.regex
local FeyCompletionHyperlinks = {}
FeyCompletionHyperlinks.__index = FeyCompletionHyperlinks

---@param opts { completion: FeyCompletion }
function FeyCompletionHyperlinks:new(opts)
  return setmetatable({
    completion = opts.completion,
    pattern = vim.regex([[\s*\[\[\zs.*$]]),
  }, FeyCompletionHyperlinks)
end

function FeyCompletionHyperlinks:get_name()
  return 'hyperlinks'
end

---@param context FeyCompletionContext
---@return number | nil
function FeyCompletionHyperlinks:get_start(context)
  return self.pattern:match_str(context.line)
end

---@param context FeyCompletionContext
---@return string[]
function FeyCompletionHyperlinks:get_results(context)
  return self.completion.links:autocomplete(context)
end

return FeyCompletionHyperlinks
