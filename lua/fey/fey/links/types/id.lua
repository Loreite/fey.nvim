local utils = require('fey.utils')
local link_utils = require('fey.fey.links.utils')

---@class FeyLinkId:FeyLinkType
---@field private files FeyFiles
local FeyLinkId = {}
FeyLinkId.__index = FeyLinkId

---@param opts { files: FeyFiles }
function FeyLinkId:new(opts)
  local this = setmetatable({
    files = opts.files,
  }, FeyLinkId)
  return this
end

---@return string
function FeyLinkId:get_name()
  return 'id'
end

---@param link string
---@return boolean
function FeyLinkId:follow(link)
  local id = self:_parse(link)
  if not id then
    return false
  end

  local files = self.files:find_files_with_property('id', id)
  if #files > 0 then
    if #files > 1 then
      utils.echo_warning(string.format('Multiple files found with id: %s, jumping to first one found', id))
    end
    return link_utils.goto_file(files[1])
  end

  local headings = self.files:find_headings_with_property('id', id)
  if #headings == 0 then
    utils.echo_warning(string.format('No heading found with id: %s', id))
    return true
  end
  if #headings > 1 then
    utils.echo_warning(string.format('Multiple headings found with id: %s', id))
    return true
  end
  local heading = headings[1]
  utils.goto_heading(heading)
  return true
end

---@return string[]
function FeyLinkId:autocomplete(_)
  return {}
end

---@private
---@param link string
---@return string?
function FeyLinkId:_parse(link)
  return link:match('^id:(.+)$')
end

return FeyLinkId
