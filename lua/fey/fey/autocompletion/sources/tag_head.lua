---Completion inside the head of a tag: its name, its values and its keys, decided by `tag_context` and filled by `data`
---@class FeyCompletionTagHead:FeyCompletionSource
local FeyCompletionTagHead = {}
FeyCompletionTagHead.__index = FeyCompletionTagHead

function FeyCompletionTagHead:new() return setmetatable({}, FeyCompletionTagHead) end

function FeyCompletionTagHead:get_name() return 'tag_head' end

---@param context FeyCompletionContext
---@return number | nil
function FeyCompletionTagHead:get_start(context)
  local ctx = require('fey.fey.autocompletion.tag_context').parse(context.line)
  context.tag_context = ctx
  return ctx and ctx.start or nil
end

---@param context FeyCompletionContext
---@return string[]
function FeyCompletionTagHead:get_results(context)
  local tag_context = require('fey.fey.autocompletion.tag_context')
  local data = require('fey.fey.autocompletion.data')
  local ctx = context.tag_context or tag_context.parse(context.line)
  if not ctx then return {} end
  if ctx.kind == 'name' then return data.tag_names() end
  if ctx.kind == 'value' then return data.values(ctx) end
  if ctx.kind == 'key' then
    -- a key is offered with its colon
    return vim.tbl_map(function(k) return k .. ': ' end, data.keys(ctx.tag))
  end
  return data.key_values(ctx)
end

return FeyCompletionTagHead
