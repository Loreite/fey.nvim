local utils = require('fey.utils')
local fs = require('fey.utils.fs')
local FeyLinkUrl = require('fey.fey.links.url')
local link_utils = require('fey.fey.links.utils')

---@class FeyLinkHeadingSearch:FeyLinkType
---@field private files FeyFiles
local FeyLinkHeadingSearch = {}
FeyLinkHeadingSearch.__index = FeyLinkHeadingSearch

---@param opts { files: FeyFiles }
function FeyLinkHeadingSearch:new(opts)
  local this = setmetatable({
    files = opts.files,
  }, FeyLinkHeadingSearch)
  return this
end

---@return string
function FeyLinkHeadingSearch:get_name()
  return 'heading'
end

---@param link string
---@return boolean
function FeyLinkHeadingSearch:follow(link)
  local opts = self:_parse(link)
  if not opts then
    return false
  end

  local file = self.files:load_file_sync(opts.file_path)
  local is_file_only = opts.type == 'file' and not opts.target

  if file then
    if is_file_only then
      return link_utils.goto_file(file)
    end

    local pattern = ('<<<?(%s[^>]*)>>>?'):format(opts.heading_text):lower()
    local headings = file:find_headings_matching_search_term(pattern, true)
    if #headings == 0 then
      headings = file:find_headings_by_title(opts.heading_text)
    end

    return link_utils.goto_oneof_headings(
      headings,
      file.filename,
      'No heading found with title: ' .. opts.heading_text
    )
  end

  local search_text = opts.heading_text

  if is_file_only then
    search_text = ''
  end

  return link_utils.open_file_and_search(opts.file_path, search_text)
end

---@param context FeyCompletionContext
---@return string[]
function FeyLinkHeadingSearch:autocomplete(context)
  local opts = self:_parse(context.base)
  if not opts then
    return {}
  end

  if opts.type == 'file' and not opts.target then
    local filenames = self.files:filenames()
    local valid_filenames = {}
    for _, f in ipairs(filenames) do
      local converted_path = fs.convert_path(opts.link_url.path, f)
      if context.matcher(converted_path, opts.link_url.path) then
        table.insert(valid_filenames, converted_path)
      end
    end

    local prefix = opts.link_url:get_protocol() == 'file' and 'file:' or ''

    return vim.tbl_map(function(path)
      return prefix .. path
    end, valid_filenames)
  end

  local file = self.files:load_file_sync(opts.file_path)

  if not file then
    return {}
  end

  local pattern = ('<<<?(%s[^>]*)>>>?'):format(opts.heading_text):lower()
  local headings = vim.tbl_map(function(heading)
    return heading:get_title()
  end, file:find_headings_matching_search_term(pattern, true))

  local matching_headings = vim.tbl_filter(function(heading)
    return context.matcher(heading:get_title(), opts.heading_text)
  end, file:get_headings())

  utils.concat(
    headings,
    vim.tbl_map(function(heading)
      return heading:get_title()
    end, matching_headings),
    true
  )
  local prefix = opts.type == 'internal' and '' or opts.link_url:get_path_with_protocol() .. '::'

  return vim.tbl_map(function(heading_title)
    return prefix .. heading_title
  end, headings)
end

---@private
---@param link string
---@return { heading_text: string, file_path: string, link_url: FeyLinkUrl, type: 'file' | 'internal', target: string | nil  } | nil
function FeyLinkHeadingSearch:_parse(link)
  local link_url = FeyLinkUrl:new(link)

  local target = link_url:get_target()
  local path = link_url:get_path()
  local heading_text = target or path

  if heading_text then
    local file_path = link_url:get_file_path()
    return {
      heading_text = heading_text,
      file_path = file_path or utils.current_file_path(),
      link_url = link_url,
      target = target,
      type = file_path and 'file' or 'internal',
    }
  end

  return nil
end

return FeyLinkHeadingSearch
