local EventManager = require('fey.events')
local events = EventManager.event
local FeyFile = require('fey.files.file')
local undotree = require('fey.utils.undotree')

_G.fey = _G.fey or {}
_G.Fey = _G.Fey or {}
---@type Fey | nil
local instance = nil

local auto_instance_keys = {
  files = true,
  agenda = true,
  capture = true,
  clock = true,
  fey_mappings = true,
  notifications = true,
  completion = true,
  links = true,
}

---@class Fey
---@field initialized boolean
---@field setup_called boolean
---@field files FeyFiles
---@field highlighter FeyHighlighter
---@field buffers FeyBuffers
---@field agenda FeyAgenda
---@field capture FeyCapture
---@field clock FeyClock
---@field completion FeyCompletion
---@field fey_mappings FeyMappings
---@field notifications FeyNotifications
---@field links FeyLinks
local Fey = {}
setmetatable(Fey, {
  __index = function(tbl, key)
    if auto_instance_keys[key] then Fey.instance() end
    return rawget(tbl, key)
  end,
})

function Fey:new()
  require('fey.fey.global')(self)
  self.initialized = false
  self.setup_called = false
  self:setup_autocmds()
  require('fey.config'):setup_ts_predicates()
  return self
end

function Fey:init()
  if self.initialized then return end
  self.buffers = require('fey.state.buffers').init()
  require('fey.events').init()
  self.highlighter = require('fey.colors.highlighter'):new()
  require('fey.colors.highlights').define_highlights()
  self.files = require('fey.files')
    :new({
      paths = require('fey.config').fey_agenda_files,
    })
    :load_sync(true, 20000)
  self.links = require('fey.fey.links'):new({ files = self.files })
  self.agenda = require('fey.agenda'):new({
    files = self.files,
    highlighter = self.highlighter,
    links = self.links,
  })
  self.capture = require('fey.capture'):new({
    files = self.files,
  })
  self.completion = require('fey.fey.autocompletion'):new({ files = self.files, links = self.links })
  self.fey_mappings = require('fey.fey.mappings'):new({
    capture = self.capture,
    agenda = self.agenda,
    files = self.files,
    links = self.links,
    completion = self.completion,
  })
  self.clock = require('fey.clock'):new({
    files = self.files,
  })
  self.statusline_debounced = require('fey.utils').debounce(
    'statusline',
    function() return self.clock:get_statusline() end,
    300
  )
  self.initialized = true
end

---@param file? string
function Fey:reload(file)
  self:init()
  return self.files:reload(file)
end

function Fey:setup_autocmds()
  local fey_augroup = vim.api.nvim_create_augroup('fey_nvim', { clear = true })
  vim.api.nvim_create_autocmd('BufWinEnter', {
    pattern = { '*.fey', '*.fey_archive' },
    group = fey_augroup,
    callback = function(event)
      if not vim.bo[event.buf].filetype or vim.bo[event.buf].filetype == '' then vim.bo[event.buf].filetype = 'fey' end
    end,
  })
  vim.api.nvim_create_autocmd('BufWritePost', {
    pattern = { '*.fey', '*.fey_archive' },
    group = fey_augroup,
    callback = function(event) self:reload(vim.fn.fnamemodify(event.file, ':p')) end,
  })
  vim.api.nvim_create_autocmd('FileType', {
    pattern = 'fey',
    group = fey_augroup,
    callback = function() self:reload(vim.fn.expand('<afile>:p')) end,
  })
  vim.api.nvim_create_autocmd('ColorScheme', {
    pattern = '*',
    group = fey_augroup,
    callback = function()
      if self.initialized then require('fey.colors.highlights').define_highlights() end
    end,
  })

  vim.api.nvim_create_autocmd({ 'BufNew' }, {
    pattern = { '*.fey', '*.fey_archive' },
    group = fey_augroup,
    callback = function(event)
      if self.buffers then self.buffers.add(event.buf) end
    end,
  })

  vim.api.nvim_create_autocmd('BufWipeout', {
    pattern = { '*.fey', '*.fey_archive' },
    group = fey_augroup,
    callback = function(event)
      if self.buffers then self.buffers.remove(event.buf) end
    end,
  })

  vim.api.nvim_create_autocmd('FileType', {
    pattern = 'fey',
    group = fey_augroup,
    callback = function(event)
      local reindexing = {}
      local reindex_pending = {}

      local function do_reindex(buf)
        if not vim.api.nvim_buf_is_valid(buf) then return end
        if undotree.was_undo_or_redo(buf) then return end
        reindexing[buf] = true
        pcall(function() vim.cmd('undojoin') end)
        local feyfile = FeyFile:new({ filename = event.file, buf = event.buf })
        local buff_changed_event = events.BufferChanged:new(feyfile)
        pcall(EventManager.dispatch, buff_changed_event)

        reindexing[buf] = nil
      end

      local function schedule_reindex(buf)
        if reindex_pending[buf] then return end
        reindex_pending[buf] = true
        vim.schedule(function()
          reindex_pending[buf] = nil
          do_reindex(buf)
        end)
      end

      vim.api.nvim_create_autocmd({ 'InsertLeave', 'TextChanged' }, {
        group = fey_augroup,
        buffer = event.buf,
        callback = function()
          if reindexing[event.buf] then return end
          schedule_reindex(event.buf)
        end,
      })

      vim.api.nvim_create_autocmd('BufWritePre', {
        group = fey_augroup,
        buffer = event.buf,
        callback = function()
          reindex_pending[event.buf] = nil
          do_reindex(event.buf)
        end,
      })
    end,
  })
end

---@param opts? FeyConfigOpts
---@return Fey
function Fey.setup(opts)
  opts = opts or {}
  local config = require('fey.config'):extend(opts)
  config:install_grammar()
  instance = Fey:new()
  instance.setup_called = true
  instance:init()
  vim.defer_fn(function()
    if config.notifications.enabled and #vim.api.nvim_list_uis() > 0 then
      Fey.files:load():next(vim.schedule_wrap(
        function()
          instance.notifications = require('fey.notifications')
            :new({
              files = Fey.files,
            })
            :start_timer()
        end
      ))
    end
    config:setup_mappings('global')
  end, 1)
  return instance
end

---@private
---@param cmd string
---@param args table
function Fey._set_dot_repeat(cmd, args)
  local repeat_action = ("'%s'"):format(cmd)
  local serialized_args = {}

  for _, arg in ipairs(args or {}) do
    if type(arg) == 'string' then
      table.insert(serialized_args, ('%q'):format(arg))
    else
      table.insert(serialized_args, tostring(arg))
    end
  end

  local args_str = table.concat(serialized_args, ', ')
  vim.cmd(
    string.format(
      [[silent! call repeat#set("\<cmd>lua require('fey').action(%s, { args = { %s } })\<CR>")]],
      repeat_action,
      args_str
    )
  )
end

---@param cmd string
---@param opts? table
function Fey.action(cmd, opts)
  opts = opts or {}
  local parts = vim.split(cmd, '.', { plain = true })
  if #parts < 2 then return end
  local fey = Fey.instance()
  local item = nil
  for i = 1, #parts - 1 do
    local part = parts[i]
    item = item and item[part] or fey[part]
  end
  if item and item[parts[#parts]] then
    local method = item[parts[#parts]]
    local args = opts.args or {}
    local success, result = pcall(method, item, unpack(args))
    if not success then
      if result.message then return require('fey.utils').echo_error(result.message) end
      if type(result) == 'string' then return require('fey.utils').echo_error(result) end
    end
    Fey._set_dot_repeat(cmd, args)
    return result
  end
end

function Fey.cron(opts)
  local ok, result = pcall(function()
    local config = require('fey.config'):extend(opts or {})
    if not config.notifications.cron_enabled then return vim.cmd([[qa!]]) end
    -- Fey.files:load_sync(true, 20000)
    instance.notifications = require('fey.notifications')
      :new({
        files = Fey.files,
      })
      :cron()
  end)

  if not ok then
    require('fey.utils').system_notification('Feymode failed to run cron: ' .. tostring(result))
    return vim.cmd([[qa!]])
  end
end

function Fey.instance()
  if not instance then instance = Fey:new() end
  instance:init()
  return instance
end

function Fey.destroy()
  if instance then
    instance = nil
    collectgarbage()
  end
end

function Fey.is_setup_called()
  if not instance then return false end
  return instance.setup_called
end

function _G.fey.statusline()
  if not instance or not instance.initialized then return '' end
  return instance.statusline_debounced() or ''
end

return Fey
