---@class FeyCompletionTags:FeyCompletionSource
---@field completion FeyCompletion
---@field private pattern vim.regex
---@field private filetags_pattern vim.regex
local FeyCompletionTags = {}
FeyCompletionTags.__index = FeyCompletionTags

---@param opts { completion: FeyCompletion }
function FeyCompletionTags:new(opts)
  return setmetatable({
    completion = opts.completion,
    filetags_pattern = vim.regex([[\c^\s*\#+filetags:\s\+]]),
    pattern = vim.regex([[:\([0-9A-Za-z_%@\#]*\)$]]),
  }, FeyCompletionTags)
end

function FeyCompletionTags:get_name()
  return 'tags'
end

---@param context FeyCompletionContext
---@return number | nil
function FeyCompletionTags:get_start(context)
  if not self.completion:is_heading_line(context.line) and not self.filetags_pattern:match_str(context.line) then
    return nil
  end
  return self.pattern:match_str(context.line)
end

---@return string[]
function FeyCompletionTags:get_results(_)
  return vim.tbl_map(function(tag)
    return table.concat({ ':', tag, ':' }, '')
  end, self.completion.files:get_tags())
end

return FeyCompletionTags
