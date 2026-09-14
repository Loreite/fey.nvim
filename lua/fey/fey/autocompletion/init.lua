---@class FeyCompletion
---@field files FeyFiles
---@field links FeyLinks
---@field private sources FeyCompletionSource[]
---@field private sources_by_name table<string, FeyCompletionSource>
---@field private fuzzy_match? boolean does completeopt has fuzzy option
---@field menu string
local FeyCompletion = {
  menu = '[Fey]',
}
FeyCompletion.__index = FeyCompletion

---@param opts { files: FeyFiles, links: FeyLinks }
function FeyCompletion:new(opts)
  local this = setmetatable({
    files = opts.files,
    links = opts.links,
    sources = {},
    sources_by_name = {},
    fuzzy_match = vim.tbl_contains(vim.opt_local.completeopt:get(), 'fuzzy'),
  }, FeyCompletion)
  this:setup_builtin_sources()
  this:register_frameworks()
  return this
end

function FeyCompletion:setup_builtin_sources()
  self:add_source(require('fey.fey.autocompletion.sources.todo_keywords'):new())
  self:add_source(require('fey.fey.autocompletion.sources.tags'):new({ completion = self }))
  self:add_source(require('fey.fey.autocompletion.sources.plan'):new({ completion = self }))
  self:add_source(require('fey.fey.autocompletion.sources.directives'):new())
  self:add_source(require('fey.fey.autocompletion.sources.properties'):new({ completion = self }))
  self:add_source(require('fey.fey.autocompletion.sources.hyperlinks'):new({ completion = self }))
end

---@param source FeyCompletionSource
function FeyCompletion:add_source(source)
  if self.sources_by_name[source:get_name()] then
    error('Completion source ' .. source:get_name() .. ' already exists', 0)
  end
  self.sources_by_name[source:get_name()] = source
  table.insert(self.sources, source)
end

---@param context FeyCompletionContext
---@return FeyCompletionItem
function FeyCompletion:complete(context)
  local results = {}
  context.base = context.base or ''
  if not context.matcher then
    context.matcher = self:_build_matcher(context)
  end
  for _, source in ipairs(self.sources) do
    if source:get_start(context) then
      vim.list_extend(results, self:_get_valid_results(source:get_results(context), context))
    end
  end

  return results
end

---@param results string[]
---@param context FeyCompletionContext
---@return FeyCompletionItem[]
function FeyCompletion:_get_valid_results(results, context)
  local valid_results = {}
  for _, item in ipairs(results) do
    if context.matcher(item, context.base) then
      table.insert(valid_results, {
        word = item,
        menu = self.menu,
      })
    end
  end

  return valid_results
end

---@param context FeyCompletionContext
function FeyCompletion:get_start(context)
  for _, source in ipairs(self.sources) do
    local start = source:get_start(context)
    if start then
      return start
    end
  end

  return -1
end

function FeyCompletion:omnifunc(findstart, base)
  if findstart == 1 then
    self._context = { line = self:get_line() }
    return self:get_start(self._context)
  end

  self._context = self._context or { line = self:get_line() }
  self._context.base = base
  self._context.fuzzy = self.fuzzy_match
  return self:complete(self._context)
end

---@private
---@param context FeyCompletionContext
---@return fun(value: string, pattern: string):boolean
function FeyCompletion:_build_matcher(context)
  return function(value, pattern)
    pattern = pattern or ''
    if pattern == '' then
      return true
    end
    if context.fuzzy then
      return #vim.fn.matchfuzzy({ value }, pattern) > 0
    end
    return value:find('^' .. vim.pesc(pattern)) ~= nil
  end
end

function FeyCompletion:get_line()
  local cursor = vim.api.nvim_win_get_cursor(0)
  return vim.api.nvim_get_current_line():sub(1, cursor[2])
end

---@param line string
function FeyCompletion:is_heading_line(line)
  return line:find([[^%*+%s+]]) ~= nil
end

function FeyCompletion:register_frameworks()
  require('fey.fey.autocompletion.cmp')
end

---@param arg_lead string
---@return string[]
function FeyCompletion:complete_links_from_input(arg_lead)
  local context = {
    base = arg_lead,
    fuzzy = self.fuzzy_match,
  }
  context.matcher = self:_build_matcher(context)

  return self.links:autocomplete(context)
end

return FeyCompletion
