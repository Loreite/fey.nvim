local colors = require('fey.colors')
local Range = require('fey.files.elements.range')
local FeyAgendaLineToken = require('fey.agenda.view.token')
local utils = require('fey.utils')
---@class FeyAgendaLineOpts
---@field heading? FeyHeading
---@field highlighter? FeyHighlighter
---@field hl_group? string Highlight group for the whole line content
---@field line_hl_group? string Highlight group for the whole line (including white space)
---@field metadata? table<string, any>
---@field separator? string

---@class FeyAgendaLine:FeyAgendaLineOpts
---@field view FeyAgendaView
---@field highlighter FeyHighlighter
---@field line_nr number
---@field col_counter number
---@field heading? FeyHeading
---@field tokens? FeyAgendaLineToken[]
local FeyAgendaLine = {}
FeyAgendaLine.__index = FeyAgendaLine

---@param opts? FeyAgendaLineOpts
---@return FeyAgendaLine
function FeyAgendaLine:new(opts)
  opts = opts or {}
  return setmetatable({
    tokens = {},
    col_counter = 1,
    heading = opts.heading,
    highlighter = opts.highlighter,
    hl_group = opts.hl_group,
    line_hl_group = opts.line_hl_group,
    separator = opts.separator or ' ',
    metadata = opts.metadata or {},
  }, FeyAgendaLine)
end

---@param token_opts FeyAgendaLineTokenOpts
---@param line_opts? FeyAgendaLineOpts
---@return FeyAgendaLine
function FeyAgendaLine:single_token(token_opts, line_opts)
  local line = FeyAgendaLine:new(line_opts)
  line:add_token(FeyAgendaLineToken:new(token_opts))
  return line
end

---@param token FeyAgendaLineToken
function FeyAgendaLine:add_token(token)
  -- Add offset because of the concatenation later
  token.highlighter = self.highlighter
  local concat_offset = #self.tokens > 0 and #self.separator or 0
  local length = #token.content
  local start_col = self.col_counter + concat_offset
  token.range = Range:new({
    start_line = self.line_nr,
    start_col = start_col,
    end_line = self.line_nr,
    end_col = start_col + length,
  })
  table.insert(self.tokens, token)
  self.col_counter = self.col_counter + length + concat_offset
end

---@return { content: string, highlights: { hlgroup: string, range: FeyRange }[], virt_texts: { content: string, hl_groups: string[] }[] }
function FeyAgendaLine:compile()
  local result = {
    content = {},
    highlights = {},
    virt_texts = {},
  }

  if self.hl_group then
    local line_range = Range.from_line(self.line_nr)
    line_range.end_col = -1
    table.insert(result.highlights, {
      hlgroup = self.hl_group,
      range = line_range,
    })
  end
  if self.line_hl_group then
    local line_range = Range.from_line(self.line_nr)
    line_range.end_col = -1
    table.insert(result.highlights, {
      hlgroup = self.line_hl_group,
      whole_line = true,
      range = line_range,
    })
  end

  for _, token in ipairs(self.tokens) do
    token.range.start_line = self.line_nr
    token.range.end_line = self.line_nr
    token.highlighter = self.highlighter
    if token.virt_text_pos then
      local hl_groups = { token.hl_group }
      if self.hl_group then
        table.insert(hl_groups, 1, self.hl_group)
      end
      table.insert(result.virt_texts, {
        content = token.content,
        hl_groups = hl_groups,
        range = token.range,
        virt_text_pos = token.virt_text_pos,
      })
    else
      table.insert(result.content, token.content)
      local hl = token:get_highlights()
      if #hl > 0 then
        vim.list_extend(result.highlights, hl)
      end
    end
  end

  return {
    content = table.concat(result.content, self.separator),
    highlights = result.highlights,
    virt_texts = result.virt_texts,
  }
end

function FeyAgendaLine:render()
  local compiled = self:compile()
  local bufnr = self.view.bufnr
  colors.clear_extmarks(bufnr, self.line_nr - 1, self.line_nr - 1)
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, self.line_nr - 1, self.line_nr, false, { compiled.content })
  vim.bo[bufnr].modifiable = false
  colors.apply_highlights(compiled.highlights, false, bufnr)
  colors.virtual_text(compiled.virt_texts, bufnr)
end

return FeyAgendaLine
