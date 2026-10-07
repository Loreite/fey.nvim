-- Writing links: store a link to a heading, pick a file or heading from the index and insert the link tag.
--
--   `store` remembers the heading under the cursor (`fey_store_link`); `insert` (`fey_insert_link`) offers the
--   stored ones first, then the files of the hollow and the headings of the file chosen, and writes
--   `{@ link, path; desc: Title; section: I.A. @}` at the cursor, over the link tag the cursor is in, or over the
--   visual selection, which becomes the description. With `fey_id_link_to_fey_use_id` a stored heading gets an
--   id and the link is `{@ link, id:..; desc: Title @}`, which follows the heading when it moves.
local config = require('fey.config')

local M = {}

---@class FeyStoredLink
---@field path string absolute
---@field signature? string
---@field title string
---@field id? string

---@type FeyStoredLink[]
M.stored = {}

---Remember a heading, most recent first
---@param heading FeyHeading
---@return FeyStoredLink
function M.store(heading)
  if heading.abs then
    -- an item of the agenda
    local item = { path = heading.abs, signature = heading.signature, title = heading.title or '' }
    M.stored = vim.tbl_filter(function(e) return not (e.path == item.path and e.signature == item.signature) end, M.stored)
    table.insert(M.stored, 1, item)
    return item
  end
  local sig = heading:node():field('signature')[1]
  local entry = {
    path = vim.fn.fnamemodify(heading.file.filename, ':p'),
    signature = sig and vim.trim(heading.file:get_node_text(sig)) or nil,
    title = heading:get_title() or '',
    id = config.fey_id_link_to_fey_use_id and heading:id_get_or_create() or nil,
  }
  M.stored = vim.tbl_filter(
    function(e) return not (e.path == entry.path and e.signature == entry.signature) end,
    M.stored
  )
  table.insert(M.stored, 1, entry)
  return entry
end

---The text of the link to an entry: a path inside the hollow is written relative to its root
---@param entry FeyStoredLink
---@param desc? string
---@return string
function M.link_text(entry, desc)
  local api = require('fey.api')
  desc = desc or entry.title
  if entry.id then return api.link_text('id:' .. entry.id, { desc = desc }) end
  local vault = require('fey.vault').for_path(entry.path) or require('fey.vault').current()
  local target = entry.path
  if vault then target = vim.fs.relpath(vault.root, entry.path) or target end
  return api.link_text(target, { desc = desc, section = entry.signature })
end

---Choose a link target: a stored link, or a file of the hollow and then one of its headings
---@param vault? FeyVault
---@param on_pick fun(entry: FeyStoredLink|nil)
function M.pick(vault, on_pick)
  local fuzzy = require('fey.ui.fuzzy')
  local items, lookup = {}, {}
  for _, e in ipairs(M.stored) do
    local text = ('★ %s%s'):format(e.title, e.signature and (' (' .. e.signature .. ')') or '')
    items[#items + 1] = { text = text, desc = vim.fn.fnamemodify(e.path, ':t') }
    lookup[text] = { stored = e }
  end
  for _, f in ipairs(vault and vault:files() or {}) do
    items[#items + 1] = { text = f.path, desc = f.title }
    lookup[f.path] = { file = f }
  end
  fuzzy.open({
    prompt = 'Link to',
    items = items,
    on_confirm = function(item)
      local hit = item and lookup[item.text]
      if not hit then return on_pick(nil) end
      if hit.stored then return on_pick(hit.stored) end
      local file = hit.file
      local abs = vault:abs(file.path)
      local entries, headings = {}, {}
      table.insert(entries, { text = '(the file)', desc = file.title })
      headings['(the file)'] = { path = abs, title = file.title or '' }
      for _, h in ipairs(vault:headings(file.path)) do
        local text = vim.trim(('%s %s'):format(h.signature or '', h.title or ''))
        table.insert(entries, { text = text })
        headings[text] = { path = abs, signature = h.signature, title = h.title or '' }
      end
      if #entries == 1 then return on_pick(headings['(the file)']) end
      fuzzy.open({
        prompt = 'Heading',
        items = entries,
        on_confirm = function(h) on_pick(h and headings[h.text] or nil) end,
        on_cancel = function() on_pick(nil) end,
      })
    end,
    on_cancel = function() on_pick(nil) end,
  })
end

---Write a link tag: over the link tag under the cursor, over a visual selection, or at the cursor
---@param text string
---@param selection? { srow: integer, scol: integer, erow: integer, ecol: integer } 0 based, end exclusive
local function write(text, selection)
  local bufnr = vim.api.nvim_get_current_buf()
  local links = require('fey.links')
  local node = not selection and links.tag_at_cursor(bufnr)
  if node and (node:type() == 'scope_tag' or node:type() == 'line_tag') then
    local sr, sc, er, ec = node:range()
    vim.api.nvim_buf_set_text(bufnr, sr, sc, er, ec, { text })
    return
  end
  if selection then
    vim.api.nvim_buf_set_text(bufnr, selection.srow, selection.scol, selection.erow, selection.ecol, { text })
    return
  end
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  vim.api.nvim_buf_set_text(bufnr, row - 1, col, row - 1, col, { text })
  vim.api.nvim_win_set_cursor(0, { row, col + #text })
end

---The visual selection of one line, if any
---@return { srow: integer, scol: integer, erow: integer, ecol: integer }|nil, string|nil
local function visual_selection()
  local mode = vim.fn.mode()
  if mode ~= 'v' and mode ~= 'V' and mode ~= '\22' then return nil end
  local region = vim.fn.getregionpos(vim.fn.getpos('v'), vim.fn.getpos('.'))
  if #region ~= 1 then return nil end
  local from, to = region[1][1], region[1][2]
  local sel = { srow = from[2] - 1, scol = from[3] - 1, erow = to[2] - 1, ecol = to[3] }
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'nx', false)
  local text = vim.api.nvim_buf_get_text(0, sel.srow, sel.scol, sel.erow, sel.ecol, {})[1]
  return sel, text
end

---Pick a target and write the link (`fey_insert_link`)
function M.insert()
  local selection, selected = visual_selection()
  local name = vim.api.nvim_buf_get_name(0)
  local vault = (name ~= '' and require('fey.vault').for_path(name)) or require('fey.vault').current()
  local bufnr = vim.api.nvim_get_current_buf()
  M.pick(vault, function(entry)
    if not entry or not vim.api.nvim_buf_is_valid(bufnr) then return end
    vim.api.nvim_set_current_buf(bufnr)
    write(M.link_text(entry, selected), selection)
  end)
end

return M
