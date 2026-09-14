local fey = require('fey')
local utils = require('fey.utils')
local fs = require('fey.utils.fs')
local Url = require('fey.fey.hyperlinks.url')
local Link = require('fey.fey.hyperlinks.link')
local config = require('fey.config')
local Hyperlinks = {
  stored_links = {},
}

---@param url FeyUrl
local function get_file_from_url(url)
  local file_path = url:get_file()
  local canonical_path = file_path and fs.get_real_path(file_path)
  return canonical_path and fey.files:get(canonical_path) or fey.files:get_current_file()
end

---@param url FeyUrl
---@return string[]
function Hyperlinks.find_by_filepath(url)
  local filenames = fey.files:filenames()
  local file_base = url:get_file()
  if not file_base then
    return {}
  end
  --TODO integrate with fey.utils.fs or fey.objects.url
  local valid_filenames = {}
  for _, f in ipairs(filenames) do
    if f:find('^' .. file_base) then
      if url.realpath then
        f = f:gsub(file_base, url.path)
      end
      table.insert(valid_filenames, f)
    end
  end

  local protocol = url.protocol
  local prefix = protocol and protocol == 'file' and 'file:' or ''

  return vim.tbl_map(function(path)
    return prefix .. path
  end, valid_filenames)
end

---@param url FeyUrl
---@return FeyHeading[]
function Hyperlinks.find_by_custom_id_property(url)
  local custom_id = url:get_custom_id() or ''
  local file = get_file_from_url(url)
  return file:find_headings_with_property_matching('CUSTOM_ID', custom_id)
end

---@param url FeyUrl
---@return fun(headings: FeyHeading[]): string[]
function Hyperlinks.as_custom_id_anchors(url)
  local prefix = url:is_file_custom_id() and url:get_file_with_protocol() .. '::' or ''
  return function(headings)
    return vim.tbl_map(function(heading)
      ---@cast heading FeyHeading
      local custom_id = heading:get_property('custom_id', false)
      return ('%s#%s'):format(prefix, custom_id)
    end, headings)
  end
end

---@param url FeyUrl
---@param omit_prefix? boolean
---@return fun(headings: FeyHeading[]): string[]
function Hyperlinks.as_heading_anchors(url, omit_prefix)
  local prefix = url:is_file_heading() and url:get_file_with_protocol() .. '::' or ''
  return function(headings)
    return vim.tbl_map(function(heading)
      local title = (omit_prefix and '' or '*') .. heading:get_title()
      return ('%s%s'):format(prefix, title)
    end, headings)
  end
end

---@param url FeyUrl
---@return FeyHeading[]
function Hyperlinks.find_by_title(url)
  local heading = url:get_heading()
  if not heading then
    return {}
  end
  local file = get_file_from_url(url)
  return file:find_headings_by_title(heading)
end

function Hyperlinks.find_by_plain_title(url)
  local heading = url:get_plain()
  if not heading then
    return {}
  end
  return fey.files:get_current_file():find_headings_by_title(heading)
end

local function as_dedicated_anchor_pattern(anchor_str)
  return string.format('<<<?(%s[^>]*)>>>?', anchor_str):lower()
end

---@param url FeyUrl
---@return FeyHeading[]
function Hyperlinks.find_by_dedicated_target(url)
  local anchor = url:get_plain()
  if not anchor then
    return {}
  end
  return fey.files:get_current_file():find_headings_matching_search_term(as_dedicated_anchor_pattern(anchor), true)
end

---@param url FeyUrl
---@return fun(headings: FeyHeading[]): string[]
function Hyperlinks.as_dedicated_targets(url)
  return function(headings)
    local targets = {}
    local term = as_dedicated_anchor_pattern(url:get_plain())
    for _, heading in ipairs(headings) do
      for m in heading:get_title():lower():gmatch(term) do
        table.insert(targets, m)
      end
      for _, content in ipairs(heading:content()) do
        for m in content:lower():gmatch(term) do
          table.insert(targets, m)
        end
      end
    end
    return targets
  end
end

---@param url FeyUrl
---@return fun(headings: FeyHeading[]): table<string>
function Hyperlinks.as_dedicated_anchors_or_internal_titles(url)
  return function(headings)
    local dedicated_anchors = Hyperlinks.as_dedicated_targets(url)(headings)
    local fuzzy_titles = Hyperlinks.as_heading_anchors(url, true)(headings)
    return utils.concat(dedicated_anchors, fuzzy_titles, true)
  end
end

---@param url FeyUrl
---@return FeyHeading[], fun(heading: FeyHeading[]): string[]
function Hyperlinks.find_matching_links(url)
  local result = {}
  local mapper = function(item)
    return item
  end
  if not url then
    return result, mapper
  elseif url:is_custom_id() then
    result = Hyperlinks.find_by_custom_id_property(url)
    mapper = Hyperlinks.as_custom_id_anchors(url)
  elseif url:is_heading() then
    result = Hyperlinks.find_by_title(url)
    mapper = Hyperlinks.as_heading_anchors(url)
  elseif url:is_file_only() then
    result = Hyperlinks.find_by_filepath(url)
  elseif url:is_plain() then
    result = utils.concat(Hyperlinks.find_by_dedicated_target(url), Hyperlinks.find_by_plain_title(url))
    mapper = Hyperlinks.as_dedicated_anchors_or_internal_titles(url)
  end

  return result, mapper
end

---@param heading FeyHeading
---@param path? string
function Hyperlinks.get_link_to_heading(heading, path)
  local title = heading:get_title()

  if config.fey_id_link_to_fey_use_id then
    local id = heading:id_get_or_create()
    if id then
      return ('id:%s::*%s'):format(id, title)
    end
  end

  path = path or utils.current_file_path()
  return ('file:%s::*%s'):format(path, title)
end

---@param file FeyFile
---@param path? string
function Hyperlinks.get_link_to_file(file, path)
  local title = file:get_title()

  if config.fey_id_link_to_fey_use_id then
    local id = file:id_get_or_create()
    if id then
      return ('id:%s::*%s'):format(id, title)
    end
  end

  path = path or file.filename
  return ('file:%s::*%s'):format(path, title)
end

---@param heading FeyHeading
function Hyperlinks.store_link_to_heading(heading)
  local title = heading:get_title()
  Hyperlinks.stored_links[Hyperlinks.get_link_to_heading(heading)] = title
end

---@param arg_lead string
---@return string[]
function Hyperlinks.autocomplete_links(arg_lead)
  local url = Url:new(arg_lead)
  local result, mapper = Hyperlinks.find_matching_links(url)

  if url:is_file_only() or url:is_custom_id() or url:is_heading() then
    return mapper(result)
  end

  return vim.tbl_keys(Hyperlinks.stored_links)
end

---@return FeyLink|nil, table | nil
function Hyperlinks.get_link_under_cursor()
  local line = vim.fn.getline('.')
  local col = vim.fn.col('.') or 0
  return Link.at_pos(line, col)
end

function Hyperlinks.insert_link(link_location)
  return fey.links:insert_link(link_location)
end

return Hyperlinks
