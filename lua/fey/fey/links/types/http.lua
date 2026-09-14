---@class FeyLinkHttp:FeyLinkType
---@field private files FeyFiles
local FeyLinkHttp = {}
FeyLinkHttp.__index = FeyLinkHttp

---@param opts { files: FeyFiles }
function FeyLinkHttp:new(opts)
  local this = setmetatable({
    files = opts.files,
  }, FeyLinkHttp)
  return this
end

---@return string
function FeyLinkHttp:get_name()
  return 'http'
end

---@param link string
---@return boolean
function FeyLinkHttp:follow(link)
  local url = self:_parse(link)
  if not url then
    return false
  end

  vim.ui.open(url)
  return true
end

---@return string[]
function FeyLinkHttp:autocomplete(_)
  return {}
end

---@private
---@param link string
---@return string | nil
function FeyLinkHttp:_parse(link)
  local is_url = link:match('^https?:.+$')
  if is_url then
    return link
  end

  return nil
end

return FeyLinkHttp
