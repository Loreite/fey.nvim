---@class FeyApiHeading
---@field file FeyApiFile
---@field ord integer position in the file, 1 for the first heading
---@field parent_ord? integer
---@field level integer number of segments of the signature
---@field signature string e.g. `I.A.`
---@field title string
---@field path string titles from the top heading down to this one, joined by `/`
---@field line integer 1-based first line
---@field end_line integer 1-based last line of the section (including subsections)
---@field data any data of the section when it has no subsections (see the data model of Fey)
---@field labels string[] labels given inside this section
local FeyHeading = {}
FeyHeading.__index = FeyHeading

---@private
---@param file FeyApiFile
---@param row table row of the `headings` table
---@param labels string[]
---@return FeyApiHeading
function FeyHeading._new(file, row, labels)
  return setmetatable({
    file = file,
    ord = row.ord,
    parent_ord = row.parent_ord,
    level = row.level,
    signature = row.signature,
    title = row.title,
    path = row.path,
    line = row.line,
    end_line = row.end_line,
    data = row.data,
    labels = labels,
  }, FeyHeading)
end

---The heading this one sits under
---@return FeyApiHeading|nil
function FeyHeading:parent()
  if not self.parent_ord then return nil end
  return self.file.headings[self.parent_ord]
end

---The headings directly below this one
---@return FeyApiHeading[]
function FeyHeading:children()
  local out = {}
  for _, h in ipairs(self.file.headings) do
    if h.parent_ord == self.ord then out[#out + 1] = h end
  end
  return out
end

---Sections that link to this heading with a `section` tag (or a link with a `section:` attribute)
---@return table[] rows `path`, `line`, `kind`, `target`
function FeyHeading:backlinks() return self.file.vault:backlinks(self.file.path, self.signature) end

---Open the file at this heading
---@param mode? 'split'|'vsplit'|'tab'|'current'
function FeyHeading:jump(mode)
  self.file:open(mode)
  pcall(vim.api.nvim_win_set_cursor, 0, { self.line, 0 })
  vim.cmd('normal! zvzz')
end

return FeyHeading
