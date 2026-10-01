local config = require('fey.config')
local utils = require('fey.utils')

local Tags = {}

---@type vim.treesitter.Query
local query = nil
local timers = {}

local function set_backup(bufnr, key, val)
  local backup = vim.b[bufnr].fey_config_backup or {}
  if backup[key] == nil then
    backup[key] = val
    vim.b[bufnr].fey_config_backup = backup
  end
end

Tags.key_handlers = {
  colorscheme = function(bufnr, theme_name, ctx)
    if not ctx.restore then ctx.set_backup(bufnr, 'colorscheme', vim.g.colors_name or 'default') end
    if vim.api.nvim_get_current_buf() == bufnr and vim.g.colors_name ~= theme_name then
      vim.schedule(function() pcall(vim.cmd.colorscheme, theme_name) end)
    end
  end,

  -- Optional: run arbitrary neovim commands directly (e.g., cmd: "set number")
  cmd = function(_, command_string)
    pcall(function(s) vim.cmd(s) end, command_string)
  end,
}

---@param restore boolean?
local function apply_config_key(bufnr, key, val, restore)
  val = utils.unquote(val)
  if Tags.key_handlers[key] then
    local ctx = { restore = restore, set_backup = set_backup }
    local ok, err = pcall(Tags.key_handlers[key], bufnr, val, ctx)
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

local function parse_and_apply(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then return end

  local tree = vim.treesitter.get_parser(bufnr, 'fey', {}):parse()
  if not tree or not #tree then return false end
  local root = tree[1]:root()
  if root:has_error() then return false end

  local nvim = {}
  for _, node in query:iter_captures(root, bufnr) do -- id, node: (root, bufnr, 0, -1)
    local name = node:field('name')[1]
    local name_text = name and vim.treesitter.get_node_text(name, bufnr) or ''
    if name_text ~= config.fey_nvim_config_tag_name then goto continue end
    for i, kv in ipairs(node:field('key_value')) do
      nvim[i] = nvim[i] or {}
      local key = kv:field('key')[1]
      local value = kv:field('value')[1]
      if key and value then
        local key_text = vim.treesitter.get_node_text(key, bufnr)
        local value_text = vim.treesitter.get_node_text(value, bufnr)
        nvim[i][key_text] = value_text
      end
    end

    ::continue::
  end

  vim.b[bufnr].fey_config = nvim
  for _, tag in ipairs(nvim) do
    for key, val in pairs(tag) do
      apply_config_key(bufnr, key, val)
    end
  end
end

function Tags.setup(key_handlers)
  key_handlers = key_handlers or {}
  vim.validate('key_handlers', key_handlers, 'table')
  for name, handler in pairs(key_handlers) do
    vim.validate('key_handlers key', name, 'string')
    vim.validate('key_handlers.' .. name, handler, 'function')
  end
  Tags.key_handlers = vim.tbl_deep_extend('force', Tags.key_handlers, key_handlers)
  query = query or vim.treesitter.query.get('fey', 'fey_tags')

  local group = vim.api.nvim_create_augroup('FeyBufferConfig', { clear = true })

  -- vim.api.nvim_create_autocmd({ 'BufReadPost' }, {
  -- vim.api.nvim_create_autocmd({ 'BufReadPost', 'FileType' }, {
  vim.api.nvim_create_autocmd({ 'FileType' }, {
    group = group,
    pattern = 'fey',
    callback = function(args) parse_and_apply(args.buf) end,
  })

  vim.api.nvim_create_autocmd({ 'TextChanged', 'InsertLeave' }, {
    group = group,
    pattern = '*.fey',
    callback = function(args)
      local bufnr = args.buf
      if timers[bufnr] then timers[bufnr]:stop() end
      timers[bufnr] = vim.defer_fn(function() parse_and_apply(bufnr) end, 300)
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

return Tags
