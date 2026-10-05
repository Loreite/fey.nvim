-- Navigation state: the frame stack and its persistence across invocations.
--
-- A frame is one column of the navigator:
--   root      the category list (Headings, Lists, ...)
--   children  `l` on an item: its own hierarchy
--   local     `<Tab>` on a container: every object inside it
--
-- Only plain data (FeyNavRef) is persisted. On re-open the stack is replayed
-- against a fresh parse; each frame's anchor is looked up among the items of
-- the frame below it, so a frame that can no longer be resolved drops itself
-- and everything above it (step up to the nearest valid parent).

local model_mod = require('fey.ui.navigator.model')

local M = {}

---@class FeyNavFrame
---@field mode 'root'|'children'|'local'
---@field anchor? FeyNavRef      the item this frame was entered from
---@field selected? FeyNavRef    the highlighted item
---@field cursor integer         1-based index into the (filtered) view
---@field filter? string
---@field _anchor? FeyNavItem
---@field _items? FeyNavItem[]
---@field _view? FeyNavItem[]

---@class FeyNavSaved
---@field stack FeyNavFrame[]
---@field changedtick integer
---@field name string

---@type table<integer, FeyNavSaved>
M.store = {}

---@param bufnr integer
---@param stack FeyNavFrame[]
---@param changedtick integer
function M.save(bufnr, stack, changedtick)
  local plain = {}
  for i, f in ipairs(stack) do
    plain[i] = {
      mode = f.mode,
      anchor = f.anchor,
      selected = f.selected,
      cursor = f.cursor,
      filter = f.filter,
    }
  end
  M.store[bufnr] = {
    stack = plain,
    changedtick = changedtick,
    name = vim.api.nvim_buf_get_name(bufnr),
  }
end

---@param bufnr integer
---@return FeyNavSaved|nil
function M.get(bufnr)
  local saved = M.store[bufnr]
  -- a recycled buffer number holding another file is not the same document
  if saved and saved.name ~= vim.api.nvim_buf_get_name(bufnr) then
    M.store[bufnr] = nil
    return nil
  end
  return saved
end

function M.clear(bufnr)
  M.store[bufnr] = nil
end

--- Apply the frame's filter (case-insensitive substring of the label).
---@param frame FeyNavFrame
function M.refresh_view(frame)
  local f = frame.filter
  if not f or f == '' then
    frame._view = frame._items
    return
  end
  local needle = f:lower()
  local view = {}
  for _, it in ipairs(frame._items) do
    if it.label:lower():find(needle, 1, true) then
      view[#view + 1] = it
    end
  end
  frame._view = view
end

--- Load (or reload) a frame's items from the model.
---@param model FeyNavModel
---@param frame FeyNavFrame
function M.load(model, frame)
  if frame.mode == 'root' then
    frame._items = model:root_items()
  elseif frame.mode == 'local' then
    frame._items = model:local_children(frame._anchor)
  else
    frame._items = model:children(frame._anchor)
  end
  M.refresh_view(frame)
end

--- Point the cursor at `frame.selected` if it still exists, else clamp.
---@param frame FeyNavFrame
function M.place_cursor(frame)
  local view = frame._view or {}
  local idx = frame.selected and model_mod.find(frame.selected, view)
  if not idx then
    idx = math.max(1, math.min(frame.cursor or 1, #view))
  end
  frame.cursor = idx
  frame.selected = view[idx] and model_mod.to_ref(view[idx]) or nil
end

---@param model FeyNavModel
---@return FeyNavFrame[]
function M.fresh(model)
  local root = { mode = 'root', cursor = 1 }
  M.load(model, root)
  M.place_cursor(root)
  return { root }
end

---@class FeyNavRestoreInfo
---@field dropped integer   frames that could not be resolved
---@field fuzzy boolean     some anchor only matched by title/proximity

--- Replay a saved stack against `model` (AST drift reconciliation).
---@param model FeyNavModel
---@param saved FeyNavSaved|nil
---@return FeyNavFrame[] stack, FeyNavRestoreInfo info
function M.restore(model, saved)
  local info = { dropped = 0, fuzzy = false }
  if not saved or not saved.stack or #saved.stack == 0 then
    return M.fresh(model), info
  end

  local s_root = saved.stack[1]
  local root = { mode = 'root', cursor = s_root.cursor, selected = s_root.selected, filter = s_root.filter }
  M.load(model, root)
  local stack = { root }

  for i = 2, #saved.stack do
    local sf = saved.stack[i]
    local prev = stack[#stack]
    local idx, tier = model_mod.find(sf.anchor, prev._items)
    if not idx then
      info.dropped = #saved.stack - i + 1
      break
    end
    if tier and tier > 3 then
      info.fuzzy = true
    end
    local anchor = prev._items[idx]
    prev.selected = model_mod.to_ref(anchor)
    local frame = {
      mode = sf.mode,
      anchor = model_mod.to_ref(anchor),
      selected = sf.selected,
      cursor = sf.cursor,
      filter = sf.filter,
      _anchor = anchor,
    }
    M.load(model, frame)
    if #frame._items == 0 then
      -- the anchor survived but everything under it is gone: stay on the anchor
      info.dropped = #saved.stack - i + 1
      break
    end
    stack[#stack + 1] = frame
  end

  for _, f in ipairs(stack) do
    M.place_cursor(f)
  end
  return stack, info
end

return M
