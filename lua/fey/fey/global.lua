local current_file_path = string.sub(debug.getinfo(1, 'S').source, 2)
local docs_dir = vim.fn.fnamemodify(current_file_path, ':p:h:h:h:h') .. '/docs'

---@param fey Fey
---@param config FeyConfig
local function generate_agenda_object(fey, config)
  local Agenda = setmetatable({}, {
    __call = function()
      return fey.agenda:prompt()
    end,
  })

  local agenda_keys = { 'a', 't', 'm', 'M', 's' }
  if config.fey_agenda_custom_commands then
    for key, _ in pairs(config.fey_agenda_custom_commands) do
      table.insert(agenda_keys, key)
    end
  end

  table.sort(agenda_keys)

  for _, key in ipairs(agenda_keys) do
    Agenda[key] = function()
      return fey.agenda:open_by_key(key)
    end
  end

  return Agenda
end

---@param fey Fey
---@param config FeyConfig
local function generate_capture_object(fey, config)
  local Capture = setmetatable({}, {
    __call = function()
      return fey.capture:prompt()
    end,
  })

  for key, _ in pairs(config.fey_capture_templates or {}) do
    Capture[key] = function()
      return fey.capture:open_template_by_shortcut(key)
    end
  end

  return Capture
end

---@param fey Fey
local build = function(fey)
  local config = require('fey.config')

  local FeyGlobal = {
    help = function()
      vim.cmd(('tabnew %s'):format(('%s/%s'):format(docs_dir, 'index.fey')))
      vim.cmd(('tcd %s'):format(docs_dir))
    end,

    helpgrep = function()
      fey.agenda:open_view('search', {
        agenda_files = ('%s/**/*'):format(docs_dir),
      })
    end,

    install_treesitter_grammar = function()
      local installed = require('fey.config'):install_grammar()
      if not installed then
        local choice = vim.fn.confirm('Treesitter grammar is already installed. Do you want to re-install it?', '&Yes\n&No', 2)
        if choice == 1 then
          return require('fey.config'):reinstall_grammar()
        end
      end
    end,

    agenda = generate_agenda_object(fey, config),
    capture = generate_capture_object(fey, config),

    store_link = function()
      ---@type FeyHeading | nil
      local heading = nil
      if vim.bo.filetype == 'feyagenda' then
        heading = fey.agenda:get_heading_at_cursor()
      elseif vim.bo.filetype == 'fey' then
        heading = fey.files:get_current_file():get_closest_heading_or_nil()
      end
      if not heading then
        require('fey.utils').echo_error('No heading found')
        return
      end
      heading.file
        :update(function()
          fey.links:store_link_to_heading(heading)
        end)
        :wait()
      return require('fey.utils').echo_info('Stored: ' .. heading:get_title())
    end,
    indent_mode = function()
      require('fey.ui.virtual_indent').toggle_buffer_indent_mode()
    end,
  }

  _G.Fey = FeyGlobal
end

---@param opts string[]
---@return table
local function resolve_item(opts)
  ---@type table
  local obj = _G.Fey
  for _, opt in ipairs(opts) do
    if type(obj) ~= 'table' then
      return obj
    end
    if obj[opt] then
      obj = obj[opt]
    end
  end

  return obj
end

vim.api.nvim_create_user_command('Fey', function(opts)
  local item = resolve_item(opts.fargs)
  if item and (type(item) == 'function' or (getmetatable(item) and getmetatable(item).__call)) then
    return item()
  end
  require('fey.utils').echo_error(('Invalid command "Fey %s"'):format(opts.args))
end, {
  nargs = '+',
  complete = function(arg_lead, cmd_line)
    local opts = vim.split(cmd_line:sub(5), '%s+')
    local item = resolve_item(opts)
    if type(item) ~= 'table' then
      return {}
    end
    local list = vim.tbl_keys(item)

    if arg_lead == '' then
      return list
    end
    return vim.fn.matchfuzzy(list, arg_lead)
  end,
})

return build
