---@diagnostic disable: invisible
local FeyFile = require('fey.api.file')
local FeyHeading = require('fey.api.heading')
local fey = require('fey')
local Promise = require('fey.utils.promise')
local Buffers = require('fey.state.buffers')

---@class FeyApiRefileOpts
---@field source FeyApiHeading
---@field destination FeyApiFile | FeyApiHeading

---@class FeyApi
local FeyApi = {}

---@param name? string|string[] specific file names to return (absolute path). If ommitted, returns all loaded files
---@return FeyApiFile|FeyApiFile[]
function FeyApi.load(name)
  vim.validate('name', name, { 'string', 'table' }, true)
  if not name then
    return vim.tbl_map(function(file)
      return FeyFile._build_from_internal_file(file)
    end, fey.files:all())
  end

  if type(name) == 'string' then
    local file = fey.files:get(name)
    return FeyFile._build_from_internal_file(file)
  end

  if type(name) == 'table' then
    local list = {}
    for _, file in ipairs(fey.files:all()) do
      if file.filename == name then
        table.insert(list, FeyFile._build_from_internal_file(file))
      end
    end

    return list
  end
  error('Invalid argument to FeyApi.load', 0)
end

--- Get current fey buffer file
---@return FeyApiFile
function FeyApi.current()
  if vim.bo.filetype ~= 'fey' then
    error('Not an fey buffer.', 0)
  end
  local name = vim.api.nvim_buf_get_name(0)
  return FeyApi.load(name)
end

---Refile heading to another file or heading
---If executed from capture buffer, it will close the capture buffer
---@param opts FeyApiRefileOpts
---@return FeyPromise<boolean>
function FeyApi.refile(opts)
  vim.validate('source', opts.source, 'table')
  vim.validate('destination', opts.destination, 'table')

  if getmetatable(opts.source) ~= FeyHeading then
    error('Source must be an FeyApiHeading', 0)
  end

  local is_file = getmetatable(opts.destination) == FeyFile
  local is_heading = getmetatable(opts.destination) == FeyHeading

  if not is_file and not is_heading then
    error('Destination must be an FeyApiFile or FeyApiHeading', 0)
  end

  local refile_opts = {
    source_file = opts.source._section.file,
    source_heading = opts.source._section,
  }

  if is_file then
    refile_opts.destination_file = opts.destination._file
  else
    refile_opts.destination_file = opts.destination._section.file
    refile_opts.destination_heading = opts.destination._section
  end

  local source_bufnr = Buffers.get_buffer_by_filename(opts.source.file.filename)
  local is_capture = source_bufnr > -1 and vim.b[source_bufnr].fey_capture
  if is_capture then
    local capture_window = fey.capture._windows[vim.b[source_bufnr].fey_capture_window_id]
    if capture_window then
      refile_opts.template = capture_window.template
      refile_opts.capture_window = capture_window
    end
  end

  return Promise.resolve()
    :next(function()
      if is_capture then
        return fey.capture:_refile_from_capture_buffer(refile_opts)
      end
      return fey.capture:_refile_from_fey_file(refile_opts)
    end)
    :next(function()
      return true
    end)
end

--- Insert a link to a given location at the current cursor position
---
--- The expected format is
--- <protocol>:<location>::<in_file_location>
---
--- If <in_file_location> is *<heading>, <heading> is used as prefilled description for the link.
--- If <protocol> is id, this format can also be used to pass a prefilled description.
--- @param link_location string
--- @return FeyPromise<boolean>
function FeyApi.insert_link(link_location)
  return fey.links:insert_link(link_location)
end

return FeyApi
