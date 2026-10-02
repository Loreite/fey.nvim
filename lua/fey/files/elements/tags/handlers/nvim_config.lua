local config = require('fey.config')

local M = {}

local timers = {}
local key_handlers = {
  colorscheme = function(bufnr, theme_name, ctx)
    if not ctx.restore then ctx.set_backup(bufnr, 'colorscheme', vim.g.colors_name or 'default') end
    if vim.api.nvim_get_current_buf() == bufnr and vim.g.colors_name ~= theme_name then
      vim.schedule(function() pcall(vim.cmd.colorscheme, theme_name) end)
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
  -- backup[key] = val
  -- vim.b[bufnr].fey_nvim_config_backup = backup
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

function M.nvim_handler(bufnr, _, key_values, _)
  local nvim_config = vim.b[bufnr].fey_nvim_config or {}
  for key, val in pairs(key_values) do
    nvim_config[key] = val
    apply_config_key(bufnr, key, val)
  end
  vim.b[bufnr].fey_nvim_config = nvim_config
end

function M.setup_nvim_query(parse_tags)
  local group = vim.api.nvim_create_augroup('FeyBufferConfig', { clear = true })

  local apply_all_tags = function(args)
    vim.b[args.buf].fey_nvim_config = {}
    local tags = parse_tags(args.buf)
    local ok, filtered = pcall(function() return vim.iter(tags) end)
    if not ok then
      vim.notify('fey: failed to parse tags', vim.log.levels.WARN)
      return
    end
    tags = filtered:filter(function(tag) return tag.name == config.fey_nvim_config_tag_name end):totable()
    for _, tag in ipairs(tags) do
      tag:apply()
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
      apply_all_tags(args)
    end,
  })

  vim.api.nvim_create_autocmd({ 'TextChanged', 'InsertLeave' }, {
    group = group,
    pattern = '*.fey',
    callback = function(args)
      local bufnr = args.buf
      if timers[bufnr] then timers[bufnr]:stop() end
      timers[bufnr] = vim.defer_fn(function()
        apply_config(bufnr, 'fey_nvim_config_backup', nil, false)
        apply_all_tags(args)
      end, 300)
    end,
  })

  vim.api.nvim_create_autocmd({ 'BufEnter' }, {
    group = group,
    pattern = '*.fey',
    callback = function(args)
      apply_config(args.buf, 'fey_nvim_config', function(key, _) return key ~= 'buf_leave' end, false)
    end,
  })

  -- 4. Leave buffer: Reset colorscheme and options back
  vim.api.nvim_create_autocmd({ 'BufLeave' }, {
    group = group,
    pattern = '*.fey',
    callback = function(args)
      apply_config(args.buf, 'fey_nvim_config', function(key, _) return key == 'buf_leave' end, false)
      apply_config(args.buf, 'fey_nvim_config_backup', nil, true)
    end,
  })
end

return M
