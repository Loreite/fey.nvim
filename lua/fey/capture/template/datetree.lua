local utils = require('fey.utils')

---@class FeyDatetree
local Datetree = {}
Datetree.__index = Datetree

---The signature a new heading at a level starts with: `I.`, `I.A.`, `I.A.i.`, ... The reindexing that follows
---a capture numbers it properly.
---@param level integer
---@return string
local function placeholder_signature(level)
  local config = require('fey.config')
  local sequences = require('fey.utils.sequences')
  local order = config.fey_default_subheading_index_order
  local delimiters = config.fey_default_subheading_delimiter_order
  local out = require('fey.utils.constants').heading_leading_indentation
  for k = 1, level do
    local pattern = order[((k - 1) % #order) + 1]
    local delimiter = delimiters ~= '' and delimiters:sub(((k - 1) % #delimiters) + 1, ((k - 1) % #delimiters) + 1)
      or config.fey_default_subheading_delimiter
    out = out .. sequences.patterns[pattern].to_symbol(1) .. delimiter
  end
  return out
end

---The line to insert before to keep the headings of a level in date order, nil to append
---@param headings FeyHeading[]
---@param item FeyDatetreeTreeItem
---@param date FeyDate
---@param reversed boolean|nil
---@return integer|nil
local function find_target_line(headings, item, date, reversed)
  local function sorted(matches)
    if not matches[1] then return nil end
    local out = {}
    for k, i in ipairs(item.order) do
      out[k] = matches[i]
    end
    return out
  end
  local mine = sorted({ date:format(item.format):match(item.pattern) })
  assert(mine)
  local Refile = require('fey.refile')
  for _, heading in ipairs(headings) do
    local theirs = sorted({ heading:get_title():match(item.pattern) })
    if theirs then
      local same_parent = true
      for i = 1, #mine - 1 do
        if mine[i] ~= theirs[i] then same_parent = false end
      end
      if same_parent then
        local a, b = tonumber(theirs[#theirs]), tonumber(mine[#mine])
        if (reversed and a < b) or (not reversed and a > b) then
          return (Refile.subtree(heading)) - 1
        end
      end
    end
  end
end

---Find the heading of a date in the tree of the file of the current buffer, putting in the headings that are
---missing. Runs in the buffer of the file (see `fey.refile.insert`).
---@param opts FeyCaptureTemplateDatetreeOpts
---@return { line: integer, end_line: integer, level: integer }
function Datetree.ensure(opts)
  local Refile = require('fey.refile')
  local files = require('fey').instance().files
  local date = opts.date
  local tree = Datetree._get_tree_by_type(nil, opts)
  local buf = vim.api.nvim_get_current_buf()

  local function walk()
    local file = files:get_current_file()
    local headings = file:get_top_level_headings()
    local found = {}
    for i, item in ipairs(tree) do
      local title = date:format(item.format)
      local hit = utils.find(headings, function(h) return h:get_title() == title end)
      if not hit then return found, headings, i, item end
      found[i] = hit
      headings = hit:get_child_headings()
    end
    return found
  end

  local found, siblings, missing, item = walk()
  if missing then
    local at
    if #found > 0 then
      local _, last = Refile.subtree(found[#found])
      at = last
    else
      at = vim.api.nvim_buf_line_count(buf)
    end
    local before = find_target_line(siblings, item, date, opts.reversed)
    local text = {}
    for level = missing, #tree do
      vim.list_extend(text, { placeholder_signature(level) .. ' ' .. date:format(tree[level].format), '' })
    end
    local insert_at = before or at
    local all = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    if not before then
      while insert_at > 0 and all[insert_at]:match('^%s*$') do insert_at = insert_at - 1 end
      if insert_at > 0 then table.insert(text, 1, '') end
      table.remove(text) -- no blank line at the very end of a block that ends the file
    end
    vim.api.nvim_buf_set_lines(buf, insert_at, insert_at, false, text)
    files:get_current_file():reindex_headings()
    found = walk()
  end

  local day = found[#tree]
  local first, last = Refile.subtree(day)
  return { line = first, end_line = last, level = #tree }
end

---@private
---@param opts FeyCaptureTemplateDatetreeOpts
---@return FeyDatetreeTreeItem[]
function Datetree._get_tree_by_type(_, opts)
  local trees = {
    -- Each entry in the tree is considered a heading.
    -- For example, this tree has 3 entries, and the result of it is:
    -- * YEAR
    -- ** MONTH
    -- *** DAY
    -- Level (signature) is determined by the index of the tree item.
    -- You can create any tree you want, but it must have at least one item,
    -- and have fields explained below
    --
    -- format: string
    -- The lua date format to use for the tree item. This will be used to create the heading.
    -- In this example, the format is '%Y', and it will create a year (example: 2024)
    --
    -- pattern: string
    -- The lua pattern used to parse important date parts from the formatted date.
    -- For example, if `format` is set to `%Y-%m-%d %A`, it will generate something like this:
    -- 2024-02-25 Sunday
    -- To be able to compare the dates in the datetree and figure out where to put the new entries,
    -- We need to parse the date parts from the formatted date. That's where the pattern comes in.
    -- With the lua pattern `^(%d%d%d%d)%-(%d%d)%-(%d%d).*$`, we parse year, month and day.
    -- Later, datetree can figure out where to put the new entry by comparing the parsed date parts.
    --
    -- order: number[]
    -- This is the array of numbers that works in conjuction with the pattern.
    -- It needs to contain the order of parsed date parts ordered by importance.
    -- For example, if the pattern is `^(%d%d%d%d)%-(%d%d)%-(%d%d).*$`, and the order is { 1, 2, 3 },
    -- This means that comparator will first check the year (first pattern match), then month (second pattern) and then day (last pattern).
    -- If we would want to use a date format DD.MM.YYYY, we would set all options like this:
    -- format = '%d.%m.%Y'
    -- pattern = '^(%d%d)%.(%d%d)%.(%d%d%d%d)$'
    -- order = { 3, 2, 1 }
    --
    -- Order is now 3, 2, 1 because we want to compare year first, which is the 3rd match,
    -- then month, which is 2nd match, and then day, which is first.
    day = {
      {
        format = '%Y',
        pattern = '^(%d%d%d%d)$',
        order = { 1 },
      },
      {
        format = '%Y-%m %B',
        pattern = '^(%d%d%d%d)%-(%d%d).*$',
        order = { 1, 2 },
      },
      {
        format = '%Y-%m-%d %A',
        pattern = '^(%d%d%d%d)%-(%d%d)%-(%d%d).*$',
        order = { 1, 2, 3 },
      },
    },
    month = {
      {
        format = '%Y',
        pattern = '^(%d%d%d%d)$',
        order = { 1 },
      },
      {
        format = '%Y-%m %B',
        pattern = '^(%d%d%d%d)%-(%d%d).*$',
        order = { 1, 2 },
      },
    },
    week = {
      {
        format = '%Y',
        pattern = '^(%d%d%d%d)$',
        order = { 1 },
      },
      {
        format = '%Y-W%V',
        pattern = '^(%d%d%d%d)%-W(%d%d).*$',
        order = { 1, 2 },
      },
      {
        format = '%Y-%m-%d %A',
        pattern = '^(%d%d%d%d)%-(%d%d)%-(%d%d).*$',
        order = { 1, 2, 3 },
      },
    },
  }

  if opts.tree_type == 'custom' and opts.tree then
    return opts.tree
  end

  return trees[opts.tree_type]
end

return Datetree
