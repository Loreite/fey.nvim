local config = require('fey.config')

local M = {}

local timers = {}
local key_handlers = {
  colorscheme = function(bufnr, theme_name, ctx)
    if not ctx.restore then ctx.set_backup(bufnr, 'colorscheme', vim.g.colors_name or 'default') end
    if ctx.restore or vim.api.nvim_get_current_buf() == bufnr then
      if vim.g.colors_name ~= theme_name then pcall(vim.cmd.colorscheme, theme_name) end
    end
  end,

  buf_enter = function(_, command_string)
    pcall(function(s) vim.cmd(s) end, command_string)
  end,

  buf_leave = function(_, command_string)
    pcall(function(s) vim.cmd(s) end, command_string)
  end,
}

local function set_backup(bufnr, key, val)
  local backup = vim.b[bufnr].fey_nvim_config_backup or {}
  if backup[key] == nil then
    backup[key] = val
    vim.b[bufnr].fey_nvim_config_backup = backup
  end
end

---@param restore boolean?
local function apply_config_key(bufnr, key, val, restore)
  if key_handlers[key] then
    local ctx = { restore = restore, set_backup = set_backup }
    local ok, err = pcall(key_handlers[key], bufnr, val, ctx)
    if not ok then vim.notify(('fey: handler "%s" failed: %s'):format(key, err), vim.log.levels.WARN) end
  else
    local is_opt, current_val = pcall(function() return vim.bo[bufnr][key] end)
    if is_opt then
      if val == 'true' then val = true end
      if val == 'false' then val = false end
      if tonumber(val) then val = tonumber(val) end

      if not restore then set_backup(bufnr, key, current_val) end
      pcall(function() vim.bo[bufnr][key] = val end)
    end
  end
end

local function restore_key(bufnr, key)
  local backup = vim.b[bufnr].fey_nvim_config_backup or {}
  if backup[key] == nil then return end
  apply_config_key(bufnr, key, backup[key], true)
  backup[key] = nil
  vim.b[bufnr].fey_nvim_config_backup = backup
end

function M.scope_handler(tag)
  local nvim_config = vim.b[tag.bufnr].fey_nvim_config or {}
  for key, val in pairs(tag.key_values) do
    nvim_config[key] = val
    apply_config_key(tag.bufnr, key, val)
  end
  vim.b[tag.bufnr].fey_nvim_config = nvim_config
end

function M.setup_query(parse_tags)
  local group = vim.api.nvim_create_augroup('FeyBufferConfig', { clear = true })

  local apply_all_tags = function(args)
    local bufnr = args.buf
    if not vim.api.nvim_buf_is_valid(bufnr) then return end

    local old = vim.b[bufnr].fey_nvim_config or {}
    local tags = parse_tags(bufnr)
    -- parse error (e.g. mid-typing): leave current state untouched
    if not tags then return end

    vim.b[bufnr].fey_nvim_config = {}
    for _, tag in ipairs(tags) do
      if tag.name == config.fey_nvim_config_tag_name then tag:apply() end
    end

    -- only restore keys that were removed from the tag(s)
    local new = vim.b[bufnr].fey_nvim_config or {}
    for key in pairs(old) do
      if new[key] == nil then restore_key(bufnr, key) end
    end
  end

  local apply_config = function(bufnr, config_name, filter, clear_restore)
    if vim.b[bufnr][config_name] then
      local opts = vim.iter(vim.b[bufnr][config_name])
      if filter then opts:filter(filter) end
      for opt, val in opts do
        apply_config_key(bufnr, opt, val, clear_restore)
      end
      if clear_restore then vim.b[bufnr][config_name] = {} end
    end
  end

  vim.api.nvim_create_autocmd({ 'FileType' }, {
    group = group,
    pattern = 'fey',
    callback = function(args)
      if vim.b[args.buf].fey_buffer_is_loaded then return end
      vim.b[args.buf].fey_buffer_is_loaded = true
      vim.defer_fn(function() apply_all_tags(args) end, 300)
    end,
  })

  vim.api.nvim_create_autocmd({ 'TextChanged', 'InsertLeave' }, {
    group = group,
    pattern = '*.fey',
    callback = function(args)
      if timers[args.buf] then timers[args.buf]:stop() end
      timers[args.buf] = vim.defer_fn(function() apply_all_tags(args) end, 300)
    end,
  })

  vim.api.nvim_create_autocmd({ 'BufEnter' }, {
    group = group,
    pattern = '*.fey',
    callback = function(args)
      vim.defer_fn(function()
        apply_config(args.buf, 'fey_nvim_config', function(key, _) return key ~= 'buf_leave' end, false)
      end, 300)
    end,
  })

  -- 4. Leave buffer: Reset colorscheme and options back
  vim.api.nvim_create_autocmd({ 'BufLeave' }, {
    group = group,
    pattern = '*.fey',
    callback = function(args)
      vim.defer_fn(function()
        apply_config(args.buf, 'fey_nvim_config', function(key, _) return key == 'buf_leave' end, false)
        apply_config(args.buf, 'fey_nvim_config_backup', nil, true)
      end, 300)
    end,
  })
end

local function skip_test(tag) print('Skipped! name: ' .. tag.name .. ', type: ' .. tag.type) end

M.handlers = {
  scope_tag = M.scope_handler,
  -- line_tag = skip_test,
  -- block_tag = skip_test,
  -- pair_open = skip_test,
}

return M
