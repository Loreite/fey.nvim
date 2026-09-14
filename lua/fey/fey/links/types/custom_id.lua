local utils = require('fey.utils')
local FeyLinkUrl = require('fey.fey.links.url')
local link_utils = require('fey.fey.links.utils')

---@class FeyLinkCustomId:FeyLinkType
---@field private files FeyFiles
local FeyLinkCustomId = {}
FeyLinkCustomId.__index = FeyLinkCustomId

---@param opts { files: FeyFiles }
function FeyLinkCustomId:new(opts)
  local this = setmetatable({
    files = opts.files,
  }, FeyLinkCustomId)
  return this
end

---@return string
function FeyLinkCustomId:get_name()
  return 'custom_id'
end

---@param link string
---@return boolean
function FeyLinkCustomId:follow(link)
  local opts = self:_parse(link)
  if not opts then
    return false
  end

  local file = self.files:load_file_sync(opts.file_path)

  if file and vim.trim(opts.custom_id) ~= '' then
    local headings = file:find_headings_with_property('CUSTOM_ID', opts.custom_id)
    return link_utils.goto_oneof_headings(
      headings,
      file.filename,
      'No heading found with custom id: ' .. opts.custom_id
    )
  end

  return link_utils.open_file_and_search(opts.file_path, opts.custom_id)
end

---@param context FeyCompletionContext
---@return string[]
function FeyLinkCustomId:autocomplete(context)
  local opts = self:_parse(context.base)
  if not opts then
    return {}
  end

  local file = self.files:load_file_sync(opts.file_path)

  if not file then
    return {}
  end

  local headings = file:find_headings_with_property_matching('CUSTOM_ID', opts.custom_id)
  local prefix = opts.type == 'internal' and '' or opts.link_url:get_path_with_protocol() .. '::'

  return vim.tbl_map(function(heading)
    local custom_id = heading:get_property('custom_id', false)
    return prefix .. '#' .. custom_id
  end, headings)
end

---@private
---@param link string
---@return { custom_id: string, file_path: string, link_url: FeyLinkUrl, type: 'file' | 'internal'  } | nil
function FeyLinkCustomId:_parse(link)
  local link_url = FeyLinkUrl:new(link)

  local target = link_url:get_target()
  local path = link_url:get_path()

  local file_path_custom_id = target and target:match('^#(.*)$')
  local current_file_custom_id = path and path:match('^#(.*)$')

  if file_path_custom_id then
    local file_path = link_url:get_file_path()
    if not file_path then
      return nil
    end
    return {
      custom_id = file_path_custom_id,
      file_path = file_path,
      link_url = link_url,
      type = 'file',
    }
  end

  if current_file_custom_id then
    return {
      custom_id = current_file_custom_id,
      file_path = utils.current_file_path(),
      link_url = link_url,
      type = 'internal',
    }
  end

  return nil
end

return FeyLinkCustomId
