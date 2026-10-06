local config = require('fey.config')
local emphasis = require('fey.colors.highlighter.markup.emphasis')

local M = {}

local ns = vim.api.nvim_create_namespace('fey_tag_hl')
local timers = {}
local groups = {}

local FLAGS = { 'bold', 'italic', 'strike', 'underline' }
local FLAG_OPTS = { strike = 'strikethrough' }

local function is_true(value) return value ~= nil and value:lower() ~= 'false' end

--- Highlight group for the keys of a tag, created on first use. nil if no key applies.
---@param key_values table<string, string>
---@return string|nil
local function get_group(key_values)
  local def = {}
  local link = key_values.link
  if link and link ~= '' and vim.fn.hlexists(link) == 1 then
    def = vim.api.nvim_get_hl(0, { name = link, link = false })
  end
  local modified = false
  if key_values.fg and key_values.fg ~= '' then def.fg, modified = key_values.fg, true end
  if key_values.bg and key_values.bg ~= '' then def.bg, modified = key_values.bg, true end
  for _, flag in ipairs(FLAGS) do
    if key_values[flag] ~= nil then
      def[FLAG_OPTS[flag] or flag] = is_true(key_values[flag])
      modified = true
    end
  end

  if not modified then return link and vim.fn.hlexists(link) == 1 and link or nil end

  local name = 'FeyTagHl_' .. vim.fn.sha256(vim.inspect(def, { newline = '', indent = '' })):sub(1, 12)
  if not groups[name] or not vim.deep_equal(groups[name], def) then
    vim.api.nvim_set_hl(0, name, def)
    groups[name] = def
  end
  return name
end

---@param tag FeyTag
function M.handler(tag)
  local body = tag.body
  if not body then return end
  -- the first value may name an emphasis marker, which overrides all keys
  -- (`,` and `;` are head delimiters, so they are written escaped: `\,` `\;\;`)
  local first = tag.values[1] and tag.values[1]:gsub('\\(.)', '%1')
  local group = first and emphasis.marker_hl_name(first) or get_group(tag.key_values)
  if not group then return end

  local srow, scol, erow, ecol = body:range()
  pcall(vim.api.nvim_buf_set_extmark, tag.bufnr, ns, srow, scol, {
    end_row = erow,
    end_col = ecol,
    hl_group = group,
    priority = 200,
  })
end

M.handlers = {
  scope_tag = M.handler,
  line_tag = M.handler,
  block_tag = M.handler,
  pair_tag = M.handler,
}

function M.setup_query(parse_tags)
  local group = vim.api.nvim_create_augroup('FeyTagHl', { clear = true })

  local apply_all_tags = function(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    local tags = parse_tags(bufnr)
    -- parse error (e.g. mid-typing): leave current highlights untouched
    if not tags then return end

    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    for _, tag in ipairs(tags) do
      if tag.name == config.fey_hl_tag_name then tag:apply() end
    end
  end

  local schedule = function(bufnr, delay)
    if timers[bufnr] then timers[bufnr]:stop() end
    timers[bufnr] = vim.defer_fn(function() apply_all_tags(bufnr) end, delay)
  end

  vim.api.nvim_create_autocmd({ 'FileType', 'BufEnter', 'TextChanged', 'InsertLeave' }, {
    group = group,
    pattern = { 'fey', '*.fey' },
    callback = function(args) schedule(args.buf, 300) end,
  })

  -- groups built from `link` + other keys are snapshots, rebuild on new colors
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = group,
    callback = function()
      groups = {}
      for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].filetype == 'fey' then schedule(bufnr, 50) end
      end
    end,
  })
end

return M
