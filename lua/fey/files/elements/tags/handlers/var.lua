-- Handler for `var` tags on open-at-point (`<prefix>o`).
--
-- On a `{# var, name #}` scope tag, jumps to the variable definition (in the current buffer or in the
-- vault/parent vault/court file where it is defined).
-- On a definition (`line_tag`, `block_tag`, or `pair_tag`), jumps to the first reference (`{# var, name #}`
-- or `$name$`) in the current buffer.
local vars = require('fey.vars')

local M = {}

---@param tag FeyTag
local function goto_definition(tag)
  local ref = vars.name_of(tag.values, tag.key_values)
  if not ref then return end
  local _, loc = vars.resolve_location(ref, { bufnr = tag.bufnr })
  if not loc then
    vim.notify(('fey: undefined variable "%s"'):format(ref), vim.log.levels.WARN)
    return
  end
  vim.cmd([[normal! m']])
  local cur_path = vim.api.nvim_buf_get_name(tag.bufnr)
  if loc.path and loc.path ~= '' and loc.path ~= cur_path then vim.cmd.edit(vim.fn.fnameescape(loc.path)) end
  local line = math.max(1, loc.line or 1)
  local col = math.max(0, (loc.col or 1) - 1)
  pcall(vim.api.nvim_win_set_cursor, 0, { line, col })
end

---@param tag FeyTag
local function goto_reference(tag)
  local name = vars.name_of(tag.values, tag.key_values)
  if not name then return end
  local bufnr = tag.bufnr or vim.api.nvim_get_current_buf()
  local def_row = tag.node:start()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local needle = '$' .. name .. '$'
  local var_tag = vars.tag_name()

  for idx, line in ipairs(lines) do
    if idx - 1 ~= def_row then
      local col = line:find(needle, 1, true)
      if not col then
        local pat = '{[%s#@~*$%+`^]*' .. vim.pesc(var_tag) .. '%s*[,;]%s*(?:name:%s*)?' .. vim.pesc(name)
        col = line:find('{[%s#@~*$%+`^]*' .. vim.pesc(var_tag) .. '%s*[,;]%s*' .. vim.pesc(name) .. '[%s#@~*$%+`^}]')
          or line:find('{[%s#@~*$%+`^]*' .. vim.pesc(var_tag) .. '%s*[,;]%s*name:%s*' .. vim.pesc(name) .. '[%s#@~*$%+`^}]')
        local _ = pat
      end
      if col then
        vim.cmd([[normal! m']])
        pcall(vim.api.nvim_win_set_cursor, 0, { idx, col - 1 })
        return
      end
    end
  end
  vim.notify(('fey: no reference to variable "%s" in buffer'):format(name), vim.log.levels.INFO)
end

M.handlers = {
  scope_tag = goto_definition,
  line_tag = goto_reference,
  block_tag = goto_reference,
  pair_tag = goto_reference,
}

return M
