---Completion of the keys of the document data: inside a `table` tag, after `{# table;` or a semicolon
---
---    {# table; ti|   ->   title:
---
---The keys the plugin reads are listed, any other key is data of your own and needs no completion.
---@class FeyCompletionDirectives:FeyCompletionSource
---@field private pattern vim.regex
local FeyCompletionDirectives = {}
FeyCompletionDirectives.__index = FeyCompletionDirectives

---The keys of the document data that the plugin gives a meaning
FeyCompletionDirectives.KEYS = {
  'title',
  'category',
  'todo',
  'archive',
  'header_args',
  'labels',
  'id',
  'aliases',
  'author',
  'email',
}

function FeyCompletionDirectives:new()
  return setmetatable({
    pattern = vim.regex([[\v^\s*\{#\s*table\s*;(.*;)?\s*\zs\w*$]]),
  }, FeyCompletionDirectives)
end

---@param context FeyCompletionContext
---@return number | nil
function FeyCompletionDirectives:get_start(context) return self.pattern:match_str(context.line) end

function FeyCompletionDirectives:get_name() return 'directives' end

---@return string[]
function FeyCompletionDirectives:get_results(_)
  return vim.tbl_map(function(key) return key .. ': ' end, FeyCompletionDirectives.KEYS)
end

return FeyCompletionDirectives
