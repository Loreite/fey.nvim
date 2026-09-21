local config = require('fey.config')
local VirtualIndent = require('fey.ui.virtual_indent')
local ts_utils = require('fey.utils.treesitter')
local utils = require('fey.utils')
---@type vim.treesitter.Query
local query = nil

local function get_indent_pad(linenr, bufnr)
  if config:should_indent(bufnr) then
    local heading = ts_utils.closest_heading_node({ linenr, 0 })
    if not heading then return 0 end
    local _, end_col = heading:field('signature')[1]:end_()
    return end_col + 1
  end
  return 0
end

local function get_indent_for_match(matches, linenr, mode, bufnr)
  linenr = linenr or vim.v.lnum
  mode = mode or vim.fn.mode()
  local prev_linenr = vim.fn.prevnonblank(linenr - 1)
  local match = matches[linenr]
  local prev_line_match = matches[prev_linenr]
  local indent = 0

  if not match and not prev_line_match then return indent + get_indent_pad(linenr, bufnr) end

  match = match or {}
  prev_line_match = prev_line_match or {}

  if match.type == 'heading' then
    -- We ensure we check headings (even if a bit redundant) to ensure nothing else is checked below
    -- this is actually important for typing ':' because of neovim 'indentkeys' or 'cinkeys'
    return 2
  end
  if match.type == 'listitem' then
    -- We first figure out the indent of the first line of a listitem. Then we
    -- check if we're on the first line or a "hanging" line. In the latter
    -- case, we add the overhang.
    local first_line_indent = nil
    local parent_linenr = match.nesting_parent_linenr
    if parent_linenr then
      local parent_match = matches[parent_linenr]
      if parent_match.type == 'listitem' then
        -- Nested listitem. We recursively find the correct indent for this
        -- based on its parents correct indentation level.
        first_line_indent = vim.fn.indent(parent_linenr) + parent_match.overhang
      end
    end
    -- If the first_line_indent wasn't found then this is the root of the list.
    -- Treat the first level of indentation found as the starting level for the list body.
    indent = first_line_indent or match.indent
    -- If the current line is hanging content as part of the listitem but not on the same line we want to indent it
    -- such that it's in line with the general content body, not the bullet.
    --
    -- - I am the "first" line listitem
    --   I am the content body as part of the listitem, but on a different line!
    if linenr ~= match.line_nr then indent = indent + match.overhang end
    return indent
  end
  -- node type is nil while inserting!
  local is_inserting = (not match.type) or mode:match('^[iR]')
  if is_inserting and prev_line_match.type == 'listitem' and linenr - prev_linenr < 3 then
    -- While inserting, we also count the non-listitem line *after* a listitem as
    -- part of the listitem. Keep in mind that double empty lines end a list as
    -- per Fey syntax.
    --
    -- After the first line of a listitem, we have to add the overhang to the
    -- listitem's own base indent. After all further lines, we can simply copy
    -- the indentation.
    indent = get_indent_for_match(matches, prev_linenr, mode, bufnr)
    if prev_linenr == prev_line_match.line_nr then indent = indent + prev_line_match.overhang end
    return indent
  end

  if match.indent_type == 'block' or match.indent_type == 'other' then
    -- if match.indent_type == 'other' then
    -- Blocks and paragraphs evaluate their own starting base indent via get_matches
    return match.indent
  end

  return indent + get_indent_pad(linenr, bufnr)
end

local get_matches = ts_utils.memoize_by_buf_tick(function(bufnr)
  local tree = vim.treesitter.get_parser(bufnr, 'fey', {}):parse()
  if not tree or not #tree then return false end
  local matches = {}
  local mode = vim.fn.mode()
  local root = tree[1]:root()
  if root:has_error() then return false end
  for id, node in query:iter_captures(root, bufnr, 0, -1) do
    local range = ts_utils.node_to_lsp_range(node)
    local type = node:type()

    local opts = {
      type = type,
      node = node,
      parent = node:parent(),
      line_nr = range.start.line + 1,
      line_end_nr = range['end'].line,
      name = query.captures[id],
      indent = vim.fn.indent(range.start.line + 1),
    }

    if type == 'heading' then
      local _, end_col = node:field('signature')[1]:end_()
      opts.signature = end_col
      opts.indent = opts.indent + end_col + 1
      matches[range.start.line + 1] = opts
    end

    if type == 'listitem' then
      local bullet = assert(node:named_child(0))
      if not opts.overhang then opts.overhang = vim.trim(vim.treesitter.get_node_text(bullet, bufnr)):len() + 2 end

      local parent = node:parent()
      while parent and parent:type() ~= 'section' and parent:type() ~= 'listitem' do
        parent = parent:parent()
      end
      local prev_sibling = node:prev_sibling()
      opts.prev_sibling_linenr = prev_sibling and (prev_sibling:start() + 1)
      opts.nesting_parent_linenr = parent and (parent:start() + 1)

      for i = range.start.line, range['end'].line - 1 do
        matches[i + 1] = opts
      end
    end

    if type == 'block' then
      opts.indent_type = 'block'
      local head_indent = opts.indent

      for i = range.start.line, range['end'].line - 1 do
        local line_content = vim.api.nvim_buf_get_lines(bufnr, i, i+1, true)[1]
        if line_content:match('^$') then goto continue end
        local curr_indent = vim.fn.indent(i + 1)

        matches[i + 1] = vim.tbl_extend('force', opts, {
          indent = math.max(head_indent, curr_indent),
        })
        ::continue::
      end
    elseif type == 'paragraph' or type == 'drawer' or type == 'property_drawer' then
      opts.indent_type = 'other'

      if opts.indent == 2 then opts.indent = 0 end

      for i = range.start.line, range['end'].line - 1 do
        matches[i + 1] = opts
      end
    end
  end

  return matches
end)

-- Some explanation as to the caching insanity inside of this function. The `get_matches` function
-- is memoized, but that only goes so far. When a user wants to indent a large region, say with
-- `norm! 0gg=G` every indent operation will call `get_matches` and get *new* matches. For the most
-- part, this is fine, but on occasion the cache can end up invalidated when the indent operation doesn't
-- occur fast enough. When the cache is invalidated new matches are returned and this leads to an
-- issue in which the indent calculated for the line is no longer correct as it is based on bad
-- data. This causes indents, especially for lists, to be incorrect as many indents are dependent on
-- the previous node's indentation.
--
-- By caching the matches and previous line numbers matched we can effectively check if a range was
-- requested for indentation and, if so, stop requesting new matches; then we only use the initial
-- matches while updating the previous indent amounts as we return the new indents. We invalidate
-- the cached matches when the user isn't in normal mode as it's likely they're modifying buffer
-- content which requires us to get the updated matches for the changed content.
--
-- TLDR: The caching avoids some inconsistent race conditions with getting the Treesitter matches.
local buf_indentexpr_cache = {}
local function indentexpr(linenr, bufnr)
  linenr = linenr or vim.v.lnum
  local mode = vim.fn.mode()
  query = query or vim.treesitter.query.get('fey', 'fey_indent')

  bufnr = bufnr or vim.api.nvim_get_current_buf()

  -- The buffer might be invalid, which can happen, if the function is implicitly called through
  -- refile operations. In this case we fallback to autoindent.
  if bufnr == -1 or not vim.api.nvim_buf_is_valid(bufnr) then return -1 end

  local indentexpr_cache = buf_indentexpr_cache[bufnr] or { prev_linenr = -1 }
  indentexpr_cache.matches = get_matches(bufnr)

  -- Treesitter failed to parse the document (due to errors or missing tree)
  -- So we just fallback to autoindent
  if indentexpr_cache.matches == false then return -1 end

  local new_indent = get_indent_for_match(indentexpr_cache.matches, linenr, mode, bufnr)
  -- local match = indentexpr_cache.matches[linenr]

  -- if match then
  --   -- Attempt to calculate indentation from the block filetype
  --   if match.indent_type == 'block' and linenr > match.line_nr and linenr < match.line_end_nr then
  --     local block_parameters = match.node:field('parameter')
  --
  --     if block_parameters and block_parameters[1] then
  --       local block_ft = vim.treesitter.get_node_text(block_parameters[1], bufnr)
  --
  --       if block_ft and block_ft ~= vim.bo.filetype then
  --         local curr_indentexpr = vim.filetype.get_option(block_ft, 'indentexpr') --[[@as string]]
  --
  --         if curr_indentexpr and curr_indentexpr ~= '' then
  --           curr_indentexpr = curr_indentexpr:gsub('%(%)$', '')
  --
  --           local buf_shiftwidth = vim.bo.shiftwidth
  --           vim.bo.shiftwidth = vim.filetype.get_option(block_ft, 'shiftwidth')
  --           local ok, block_ft_indent = pcall(function() return vim.fn[curr_indentexpr]() end)
  --           if ok then new_indent = math.max(block_ft_indent, vim.fn.indent(match.line_nr)) end
  --
  --           vim.bo.shiftwidth = buf_shiftwidth
  --         end
  --       end
  --     end
  --   end
  --   match.indent = new_indent
  -- end
  indentexpr_cache.prev_linenr = linenr
  buf_indentexpr_cache[bufnr] = indentexpr_cache
  return new_indent
end

local function foldtext()
  local line = vim.fn.getline(vim.v.foldstart)

  if config:hide_leading_signature(vim.api.nvim_get_current_buf()) then
    line = vim.fn.substitute(line, '\\(^\\*\\+\\)', '\\=repeat(" ", len(submatch(0))-1) . "*"', '') or ''
  end

  if vim.opt.conceallevel:get() > 0 and string.find(line, '[[', 1, true) then
    line = string.gsub(line, '%[%[(.-)%]%[?(.-)%]?%]', function(link, text)
      if text == '' then
        return link
      else
        return text
      end
    end)
  end

  return line .. config.fey_ellipsis
end

return {
  indentexpr = indentexpr,
  foldtext = foldtext,
}
