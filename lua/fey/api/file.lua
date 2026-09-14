---@diagnostic disable: invisible
local FeyHeading = require('fey.api.heading')
local fey = require('fey')
local Buffers = require('fey.state.buffers')

---@class FeyApiFile
---@field category string current file category name. By default it's only filename without extension unless defined differently via #+CATEGORY directive
---@field filename string absolute path of the current file
---@field headings FeyApiHeading[]
---@field is_archive_file boolean
---@field private _file FeyFile
local FeyFile = {}

---@param heading FeyApiHeading
---@param headings_by_id table<string, FeyApiHeading>
---@private
local function map_child_headings(heading, headings_by_id)
  if #heading._section:get_child_headings() == 0 then
    return heading
  end

  local child_headings = {}
  for _, child_section in ipairs(heading._section:get_child_headings()) do
    local child_heading = headings_by_id[child_section:get_range().start_line]
    child_heading.parent = heading
    table.insert(child_headings, child_heading)
    map_child_headings(child_heading, headings_by_id)
  end
  heading.headings = child_headings
  return heading
end

---@private
function FeyFile:_new(opts)
  local data = {}
  data.category = opts.category
  data.filename = opts.filename
  data.headings = opts.headings
  data.is_archive_file = opts.is_archive_file or false
  data._file = opts._file
  setmetatable(data, self)
  self.__index = self
  return data
end

---@param file FeyFile
---@private
function FeyFile._build_from_internal_file(file)
  local headings = {}
  local headings_by_id = {}
  for i, section in ipairs(file:get_headings()) do
    local heading = FeyHeading._build_from_internal_heading(section, i)
    table.insert(headings, heading)
    headings_by_id[section:get_range().start_line] = heading
  end

  local instance = FeyFile:_new({
    _file = file,
    category = file:get_category(),
    filename = file.filename,
    headings = headings,
    is_archive_file = file:is_archive_file(),
  })

  for _, heading in ipairs(instance.headings) do
    map_child_headings(heading, headings_by_id)
    heading.file = instance
  end

  return instance
end

--- Return refreshed instance of the file
---@return FeyApiFile
function FeyFile:reload()
  return FeyFile._build_from_internal_file(self._file:reload_sync())
end

--- Return closest heading, or nil if there are no headings found
--- If cursor is not provided, it will use current cursor position
--- @param cursor? { line: number, col: number } (1, 0)-indexed cursor position, same as returned from `vim.api.nvim_win_get_cursor(0)`
--- @return FeyApiHeading | nil
function FeyFile:get_closest_heading(cursor)
  local file = self:reload()
  local internal_heading = file._file:get_closest_heading_or_nil(cursor)
  if not internal_heading then
    return nil
  end
  for _, heading in ipairs(file.headings) do
    if heading.position.start_line == internal_heading:get_range().start_line then
      return heading
    end
  end
  return nil
end

---@param line_number number
---@return FeyApiHeading | nil
function FeyFile:get_heading_on_line(line_number)
  return vim.tbl_filter(function(heading)
    return heading.position.start_line == line_number
  end, self.headings)[1]
end

--- Get a link destination as string
---
--- Depending if fey_id_link_to_fey_use_id is set the format is
---
--- id:<uuid>::*title and the id is created if not existing
--- or
--- file:<filepath>::*title
---
--- The result is meant to be used as link_location for FeyApi.insert_link.
--- @return string
function FeyFile:get_link()
  local filename = self.filename
  local bufnr = Buffers.get_buffer_by_filename(filename)

  if bufnr == -1 or not vim.api.nvim_buf_is_loaded(bufnr) then
    -- do remote edit
    return fey.files
      :update_file(filename, function(file)
        return fey.links:get_link_to_file(file)
      end)
      :wait()
  end

  return fey.links:get_link_to_file(self._file)
end

return FeyFile
