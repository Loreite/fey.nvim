local config = require('fey.config')

local M = {}

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

M.key_handlers = {
  colorscheme = function(bufnr, theme_name)
    -- if not vim.b[bufnr].fey_config_backup.colorscheme then
    --   vim.b[bufnr].fey_config_backup.colorscheme = vim.g.colors_name or 'default'
    -- end
    set_backup(bufnr, 'colorscheme', vim.g.colors_name or 'default')
    if vim.api.nvim_get_current_buf() == bufnr then pcall(vim.cmd.colorscheme, theme_name) end
  end,

  -- Optional: run arbitrary neovim commands directly (e.g., cmd: "set number")
  cmd = function(_, command_string)
    pcall(function(s) vim.cmd(s) end, command_string)
  end,
}

-- local function is_valid_buf_option(bufnr, key)
--   return ok, val = pcall(function() return vim.bo[bufnr][key] end)
-- end
-- local function is_valid_buf_option(key)
--   local ok, info = pcall(vim.api.nvim_get_option_info2, key, { scope = 'local' })
--   -- Check if it exists and applies to buffer scope
--   return ok and (info.scope == 'buffer' or info.global_local)
-- end

local function apply_config_key(bufnr, key, val)
  vim.b[bufnr].fey_config_backup = vim.b[bufnr].fey_config_backup or {}
  if M.key_handlers[key] then -- Key matches a special command handler
    M.key_handlers[key](bufnr, val)
  -- elseif is_valid_buf_option(bufnr, key) then -- Key is a valid buffer option (e.g., shiftwidth, tabstop)
  else
    local is_opt, current_val = pcall(function() return vim.bo[bufnr][key] end)
    if is_opt then
      if val == 'true' then val = true end
      if val == 'false' then val = false end
      if tonumber(val) then val = tonumber(val) end

      if vim.b[bufnr].fey_config_backup[key] == nil then vim.b[bufnr].fey_config_backup[key] = current_val end

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

function M.setup()
  query = query or vim.treesitter.query.get('fey', 'fey_tags')

  local group = vim.api.nvim_create_augroup('FeyBufferConfig', { clear = true })

  vim.api.nvim_create_autocmd({ 'BufReadPost' }, {
    group = group,
    pattern = '*.fey',
    callback = function(args) parse_and_apply(args.buf) end,
  })

  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
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
          apply_config_key(bufnr, opt, val)
        end
      end
    end,
  })
end

return M
