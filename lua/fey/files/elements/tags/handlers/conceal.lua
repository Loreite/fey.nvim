-- The `conceal` key of the tags that run (`query`, `feydb`, `clocktable`) and of their results.
--
--   {# query, LIST FROM #design; conceal: true #}
--
-- A query tag with `conceal: true` is hidden, its head and its body, so the page shows the result. When the tag
-- runs it writes the result with `conceal: true` too, and a result with that key hides its head and its closer, not
-- its body: `[ query_result; conceal: true #]` ... `[# query_result ]`. The text comes back on the cursor line like
-- any concealed text, per `concealcursor`.
--
-- Lines the tag fills on their own are hidden whole (`conceal_lines`), a tag in the middle of a line is concealed in place.
local config = require('fey.config')

local M = {}

local ns = vim.api.nvim_create_namespace('fey_tag_conceal')
local timers = {}

---Names of the tags that run, and of their results
local function names()
  return {
    [config.fey_query_tag_name] = 'source',
    [config.fey_db_tag_name] = 'source',
    [config.fey_clocktable_tag_name] = 'source',
    [config.fey_query_result_tag_name] = 'result',
    [config.fey_db_result_tag_name] = 'result',
    [config.fey_clocktable_result_tag_name] = 'result',
  }
end

---Conceal a node: whole lines when it fills them, else the text
---@param bufnr integer
---@param node TSNode
local function conceal_node(bufnr, node)
  local sr, sc, er, ec = node:range()
  if ec == 0 and er > sr then
    er = er - 1
    ec = #(vim.api.nvim_buf_get_lines(bufnr, er, er + 1, false)[1] or '')
  end
  local first = vim.api.nvim_buf_get_lines(bufnr, sr, sr + 1, false)[1] or ''
  local last = vim.api.nvim_buf_get_lines(bufnr, er, er + 1, false)[1] or ''
  local fills = first:sub(1, sc):match('^%s*$') and last:sub(ec + 1):match('^%s*$')
  if fills then
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, sr, 0, { end_row = er, end_col = #last, conceal_lines = '' })
  else
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, sr, sc, { end_row = er, end_col = ec, conceal = '' })
  end
end

---@param tag FeyTag
function M.handler(tag)
  local kind = names()[tag.name]
  if not kind or (tag.key_values.conceal or ''):lower() ~= 'true' then return end
  if kind == 'source' then
    conceal_node(tag.bufnr, tag.node)
  elseif tag.type == 'pair_tag' then
    local open, close = tag.node:field('open')[1], tag.node:field('close')[1]
    if open then conceal_node(tag.bufnr, open) end
    if close then conceal_node(tag.bufnr, close) end
  end
end

function M.setup_query(parse_tags)
  local group = vim.api.nvim_create_augroup('FeyTagConceal', { clear = true })
  local apply_all = function(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    local tags = parse_tags(bufnr)
    if not tags then return end
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    for _, tag in ipairs(tags) do
      M.handler(tag)
    end
  end
  vim.api.nvim_create_autocmd({ 'FileType', 'BufEnter', 'TextChanged', 'InsertLeave' }, {
    group = group,
    pattern = { 'fey', '*.fey' },
    callback = function(args)
      if timers[args.buf] then timers[args.buf]:stop() end
      timers[args.buf] = vim.defer_fn(function() apply_all(args.buf) end, 100)
    end,
  })
end

M.ns = ns

return M
