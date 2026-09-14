local config = require('fey.config')
local utils = require('fey.utils')
local FeyLinkUrl = require('fey.fey.links.url')
local FeyHyperlink = require('fey.fey.links.hyperlink')
local Input = require('fey.ui.input')

---@class FeyLinks:FeyLinkType
---@field private files FeyFiles
---@field private types FeyLinkType[]
---@field private types_by_name table<string, FeyLinkType>
---@field private stored_links table<string, string>
---@field private heading_search FeyLinkHeadingSearch
local FeyLinks = {
  stored_links = {},
}
FeyLinks.__index = FeyLinks

---@param opts { files: FeyFiles }
function FeyLinks:new(opts)
  local this = setmetatable({
    files = opts.files,
    types = {},
    types_by_name = {},
  }, FeyLinks)
  this:_setup_builtin_types()
  this:_add_custom_sources()
  return this
end

---@private
function FeyLinks:_add_custom_sources()
  for i, source in ipairs(config.hyperlinks.sources) do
    if type(source.get_name) == 'function' then
      self:add_type(source)
    else
      vim.notify(('Hyperlink source at index %d must have a get_name method'):format(i), vim.log.levels.ERROR)
    end
  end
end

---@param link string
---@return boolean
function FeyLinks:follow(link)
  for _, source in ipairs(self.types) do
    if source.follow and source:follow(link) then
      return true
    end
  end

  local fey_link_url = FeyLinkUrl:new(link)
  if fey_link_url.protocol and fey_link_url.protocol ~= 'file' and fey_link_url.protocol ~= 'id' then
    utils.echo_warning(string.format('Unsupported link protocol: %q', fey_link_url.protocol))
    return false
  end

  return self.heading_search:follow(link)
end

---@param context FeyCompletionContext
---@return string[]
function FeyLinks:autocomplete(context)
  local items = vim.tbl_filter(function(stored_link)
    return context.matcher(stored_link, context.base)
  end, vim.tbl_keys(self.stored_links))

  for _, source in ipairs(self.types) do
    if source.autocomplete then
      utils.concat(items, source:autocomplete(context))
    end
  end

  utils.concat(items, self.heading_search:autocomplete(context))
  return items
end

---@param heading FeyHeading
function FeyLinks:store_link_to_heading(heading)
  self.stored_links[self:get_link_to_heading(heading)] = heading:get_title()
end

---@param heading FeyHeading
---@return string
function FeyLinks:get_link_to_heading(heading)
  local title = heading:get_title()

  if config.fey_id_link_to_fey_use_id then
    local id = heading:id_get_or_create()
    if id then
      return ('id:%s::*%s'):format(id, title)
    end
  end

  return ('file:%s::*%s'):format(heading.file.filename, title)
end

---@param file FeyFile
---@return string
function FeyLinks:get_link_to_file(file)
  local title = file:get_title()

  if config.fey_id_link_to_fey_use_id then
    local id = file:id_get_or_create()
    if id then
      return ('id:%s::*%s'):format(id, title)
    end
  end

  return ('file:%s::*%s'):format(file.filename, title)
end

---@param link_location string
function FeyLinks:insert_link(link_location, desc)
  local selected_link = FeyHyperlink:new(link_location)
  desc = desc or selected_link.url:get_target()
  if desc and (desc:match('^%*') or desc:match('^#')) then
    desc = desc:sub(2)
  end

  if selected_link.url:get_protocol() == 'id' then
    link_location = ('id:%s'):format(selected_link.url:get_path())
  end

  if not desc and vim.fn.mode() == 'v' then
    desc = utils.get_visual_selection()
  end

  return Input.open('Description: ', desc or ''):next(function(link_description)
    if not link_description then
      return false
    end
    link_location = '[' .. vim.trim(link_location) .. ']'

    if link_description ~= '' then
      link_description = '[' .. link_description .. ']'
    end

    local insert_from
    local insert_to
    local target_col = #link_location + #link_description + 2

    -- check if currently on link
    local link = FeyHyperlink.at_cursor()
    if link then
      insert_from = link.range.start_col - 1
      insert_to = link.range.end_col + 1
      target_col = target_col + link.range.start_col
    elseif vim.fn.mode() == 'v' then
      local region = vim.fn.getregionpos(vim.fn.getpos('v'), vim.fn.getpos('.'))
      insert_from = region[1][1][3] - 1
      insert_to = region[1][2][3] + 1
      target_col = target_col + region[1][1][3]
    else
      local colnr = vim.fn.col('.')
      insert_from = colnr
      insert_to = colnr + 1
      target_col = target_col + colnr
    end

    local linenr = vim.fn.line('.') or 0
    local curr_line = vim.fn.getline(linenr)
    local new_line = string.sub(curr_line, 0, insert_from)
      .. '['
      .. link_location
      .. link_description
      .. ']'
      .. string.sub(curr_line, insert_to, #curr_line)

    vim.fn.setline(linenr, new_line)
    vim.fn.cursor(linenr, target_col)
    return true
  end)
end

---@param link_type FeyLinkType
function FeyLinks:add_type(link_type)
  if self.types_by_name[link_type:get_name()] then
    error('Link type ' .. link_type:get_name() .. ' already exists', 0)
  end
  self.types_by_name[link_type:get_name()] = link_type
  table.insert(self.types, link_type)
end

---@private
function FeyLinks:_setup_builtin_types()
  self:add_type(require('fey.fey.links.types.http'):new({ files = self.files }))
  self:add_type(require('fey.fey.links.types.id'):new({ files = self.files }))
  self:add_type(require('fey.fey.links.types.line_number'):new({ files = self.files }))
  self:add_type(require('fey.fey.links.types.custom_id'):new({ files = self.files }))
  self:add_type(require('fey.fey.links.types.heading'):new({ files = self.files }))

  self.heading_search = require('fey.fey.links.types.heading_search'):new({ files = self.files })
end

return FeyLinks
