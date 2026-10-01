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

  cmd = function(_, command_string)
    pcall(function(s) vim.cmd(s) end, command_string)
  end,
}

local function set_backup(bufnr, key, val)
  local backup = vim.b[bufnr].fey_config_backup or {}
  backup[key] = val
  vim.b[bufnr].fey_config_backup = backup
  -- if backup[key] == nil then
  --   backup[key] = val
  --   vim.b[bufnr].fey_config_backup = backup
  -- end
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
  for key, val in pairs(key_values) do
    apply_config_key(bufnr, key, val)
  end
end

function M.setup_nvim_query(parse_tags)
  local group = vim.api.nvim_create_augroup('FeyBufferConfig', { clear = true })

  local apply_all = function(args)
    local tags = parse_tags(args.buf)
    vim.iter(tags):filter(function(tag) return tag.name == config.fey_nvim_config_tag_name end)
    for _, tag in ipairs(tags) do
      for key, value in pairs(tag.key_values) do
        apply_config_key(args.buf, key, value)
      end
    end
  end

  vim.api.nvim_create_autocmd({ 'FileType' }, {
    group = group,
    pattern = 'fey',
    callback = apply_all,
  })

  vim.api.nvim_create_autocmd({ 'TextChanged', 'InsertLeave' }, {
    group = group,
    pattern = '*.fey',
    callback = function(args)
      local bufnr = args.buf
      if timers[bufnr] then timers[bufnr]:stop() end
      timers[bufnr] = vim.defer_fn(apply_all, 300)
    end,
  })

  vim.api.nvim_create_autocmd({ 'BufEnter' }, {
    group = group,
    pattern = '*.fey',
    callback = function(args)
      local bufnr = args.buf

      if vim.b[bufnr].fey_config then
        for _, tag in ipairs(vim.b[bufnr].fey_config) do
          for opt, val in pairs(tag) do
            apply_config_key(bufnr, opt, val)
          end
        end
      end
    end,
  })

  -- 4. Leave buffer: Reset colorscheme and options back
  vim.api.nvim_create_autocmd({ 'BufLeave' }, {
    group = group,
    pattern = '*.fey',
    callback = function(args)
      local bufnr = args.buf

      if vim.b[bufnr].fey_config_backup then
        for opt, val in pairs(vim.b[bufnr].fey_config_backup) do
          apply_config_key(bufnr, opt, val, true)
        end
        vim.b[bufnr].fey_config_backup = {}
      end
    end,
  })
end

return M
