local utils = require('fey.utils')
local FeyLinkUrl = require('fey.fey.links.url')
local link_utils = require('fey.fey.links.utils')

---@class FeyLinkHeading:FeyLinkType
---@field private files FeyFiles
local FeyLinkHeading = {}
FeyLinkHeading.__index = FeyLinkHeading

---@param opts { files: FeyFiles }
function FeyLinkHeading:new(opts)
  local this = setmetatable({
    files = opts.files,
  }, FeyLinkHeading)
  return this
end

---@return string
function FeyLinkHeading:get_name()
  return 'heading'
end

---@param link string
---@return boolean
function FeyLinkHeading:follow(link)
  local opts = self:_parse(link)
  if not opts then
    return false
  end

  local fey_file = self.files:load_file_sync(opts.file_path)

  if fey_file and vim.trim(opts.heading) ~= '' then
    local headings = fey_file:find_headings_by_title(opts.heading)
    return link_utils.goto_oneof_headings(headings, opts.file_path, 'No heading found with title: ' .. opts.heading)
  end

  return link_utils.open_file_and_search(opts.file_path, opts.heading)
end

---@param context FeyCompletionContext
---@return string[]
function FeyLinkHeading:autocomplete(context)
  local opts = self:_parse(context.base)
  if not opts then
    return {}
  end

  local file = self.files:load_file_sync(opts.file_path)

  if not file then
    return {}
  end

  local headings = vim.tbl_filter(function(heading)
    return context.matcher(heading:get_title(), opts.heading)
  end, file:get_headings())
  local prefix = opts.type == 'internal' and '' or opts.link_url:get_path_with_protocol() .. '::'

  return vim.tbl_map(function(heading)
    local title = heading:get_title()
    return prefix .. '*' .. title
  end, headings)
end

---@private
---@param link string
---@return { heading: string, file_path: string, link_url: FeyLinkUrl, type: 'file' | 'internal'  } | nil
function FeyLinkHeading:_parse(link)
  local link_url = FeyLinkUrl:new(link)

  local target = link_url:get_target()
  local path = link_url:get_path()

  local file_path_heading = target and target:match('^%*(.*)$')
  local current_file_heading = path and path:match('^%*(.*)$')

  if file_path_heading then
    local file_path = link_url:get_file_path()
    if not file_path then
      return nil
    end
    return {
      heading = file_path_heading,
      file_path = file_path,
      link_url = link_url,
      type = 'file',
    }
  end

  if current_file_heading then
    return {
      heading = current_file_heading,
      file_path = utils.current_file_path(),
      link_url = link_url,
      type = 'internal',
    }
  end

  return nil
end

return FeyLinkHeading
