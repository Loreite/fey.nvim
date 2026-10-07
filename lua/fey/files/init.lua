-- The files the editor works on: a cache of the `FeyFile` of the buffers that are open, loaded when something asks for
-- one and forgotten when its buffer is wiped. Nothing is loaded ahead of time: what spans many files (the agenda,
-- queries, refile targets, links, tangling) reads the index of the hollows (`fey.vault`), not these.
local Promise = require('fey.utils.promise')
local FeyFile = require('fey.files.file')
local utils = require('fey.utils')
local ts_utils = require('fey.utils.treesitter')
local Listitem = require('fey.files.elements.listitem')

---@class FeyLoadFileOpts
---@field persist? boolean unused, kept for the callers that still pass it

---@class FeyFiles
---@field all_files table<string, FeyFile> the files loaded so far, by absolute path
local FeyFiles = {}
FeyFiles.__index = FeyFiles

---@param _? table unused: there is nothing to preload, the old `paths` are gone
---@return FeyFiles
function FeyFiles:new(_)
  local data = setmetatable({ all_files = {} }, self)
  local group = vim.api.nvim_create_augroup('FeyFilesCache', { clear = true })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    callback = function(args)
      local name = vim.api.nvim_buf_get_name(args.buf)
      if name ~= '' then data:forget(name) end
    end,
  })
  return data
end

---@param filename string
---@return string
local function resolved(filename) return vim.fn.resolve(vim.fn.fnamemodify(filename, ':p')) end

---Drop the file of a path from the cache
---@param filename string
function FeyFiles:forget(filename) self.all_files[resolved(filename)] = nil end

---Forget every file
---@return FeyFiles
function FeyFiles:unload()
  self.all_files = {}
  return self
end

---The files loaded so far
---@return FeyFile[]
function FeyFiles:all()
  local names = vim.tbl_keys(self.all_files)
  table.sort(names)
  return vim.tbl_map(function(name) return self.all_files[name] end, names)
end

---@return string[]
function FeyFiles:filenames()
  return vim.tbl_map(function(file) return file.filename end, self:all())
end

---The file of the current buffer
---@return FeyFile
function FeyFiles:get_current_file()
  local filename = utils.current_file_path()
  local feyfile = self:load_file_sync(filename)
  assert(feyfile, 'Current file not found or not an fey file')
  return feyfile
end

---Load a file, or read it again when it is loaded already
---@param filename string
---@param _? FeyLoadFileOpts
---@return FeyPromise<FeyFile | false>
function FeyFiles:load_file(filename, _)
  filename = resolved(filename)
  local file = self.all_files[filename]
  if file then return file:reload() end
  return FeyFile.load(filename):next(function(feyfile)
    if feyfile then self.all_files[filename] = feyfile end
    return feyfile
  end)
end

---@param filename string
---@param opts? FeyLoadFileOpts
---@param timeout? number
---@return FeyFile | false
function FeyFiles:load_file_sync(filename, opts, timeout) return self:load_file(filename, opts):wait(timeout) end

---@param filename string
---@return FeyFile
function FeyFiles:get(filename)
  local file = self:load_file_sync(filename)
  assert(file, 'File ' .. filename .. ' not found or is in invalid format')
  return file
end

function FeyFiles:reload(filename) return self:load_file(filename) end

---@param cursor? table (1, 0) indexed base position tuple
---@return FeyHeading
function FeyFiles:get_closest_heading(cursor)
  local file = self:load_file_sync(utils.current_file_path())
  assert(file, 'Current file is not a valid fey file')
  local heading = file:get_closest_heading(cursor)
  assert(heading, 'No heading found')
  return heading
end

function FeyFiles:get_closest_listitem()
  local get_listitem_node = function()
    local node_at_cursor = ts_utils.get_node_at_cursor()
    if node_at_cursor and node_at_cursor:type() == 'list' then return node_at_cursor:named_child(0) end
    return ts_utils.closest_node(node_at_cursor, 'listitem')
  end

  local node = get_listitem_node()
  if node then return Listitem:new(node, self:get_current_file()) end
  return nil
end

---@param cursor? table (1, 0) indexed base position tuple
---@return FeyHeading | nil
function FeyFiles:get_closest_heading_or_nil(cursor)
  local file = self:load_file_sync(utils.current_file_path())
  return file and file:get_closest_heading_or_nil(cursor) or nil
end

---@param filename string
---@param action fun(...:FeyFile):any
function FeyFiles:update_file(filename, action)
  local file = self:load_file_sync(filename)
  if not file then return Promise.resolve() end
  return file:update(action)
end

return FeyFiles
