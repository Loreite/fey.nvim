---Completion of the target of a link tag: the files of the hollow, `{@ link, no|` or `{# link, no|`
---@class FeyCompletionHyperlinks:FeyCompletionSource
---@field completion FeyCompletion
---@field private pattern vim.regex
local FeyCompletionHyperlinks = {}
FeyCompletionHyperlinks.__index = FeyCompletionHyperlinks

---@param opts { completion: FeyCompletion }
function FeyCompletionHyperlinks:new(opts)
  return setmetatable({
    completion = opts.completion,
    pattern = vim.regex([[\v\{[#@]\s*link\s*,\s*\zs[^,;]*$]]),
  }, FeyCompletionHyperlinks)
end

function FeyCompletionHyperlinks:get_name() return 'hyperlinks' end

---@param context FeyCompletionContext
---@return number | nil
function FeyCompletionHyperlinks:get_start(context) return self.pattern:match_str(context.line) end

---@param context FeyCompletionContext
---@return string[]
function FeyCompletionHyperlinks:get_results(context)
  local fey_vault = require('fey.vault')
  local name = vim.api.nvim_buf_get_name(0)
  local vault = (name ~= '' and fey_vault.for_path(name)) or fey_vault.current()
  local items = {}
  for _, file in ipairs(vault and vault:files() or {}) do
    if context.matcher(file.path, context.base) then items[#items + 1] = file.path end
  end
  return items
end

return FeyCompletionHyperlinks
