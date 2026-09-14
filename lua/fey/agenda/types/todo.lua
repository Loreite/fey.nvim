local config = require('fey.config')
local AgendaView = require('fey.agenda.view.init')
local Files = require('fey.files')
local AgendaLine = require('fey.agenda.view.line')
local AgendaFilter = require('fey.agenda.filter')
local AgendaLineToken = require('fey.agenda.view.token')
local utils = require('fey.utils')
local agenda_highlights = require('fey.colors.highlights')
local hl_map = agenda_highlights.get_agenda_hl_map()
local SortingStrategy = require('fey.agenda.sorting_strategy')
local Promise = require('fey.utils.promise')

---@class FeyAgendaTodosTypeOpts
---@field files FeyFiles
---@field highlighter FeyHighlighter
---@field agenda_filter FeyAgendaFilter
---@field filter? string
---@field tag_filter? string
---@field category_filter? string
---@field agenda_files string | string[] | nil
---@field header? string
---@field subheader? string
---@field todo_only? boolean
---@field sorting_strategy? FeyAgendaSortingStrategy[]
---@field remove_tags? boolean
---@field id? string

---@class FeyAgendaTodosType:FeyAgendaViewType
---@field files FeyFiles
---@field highlighter FeyHighlighter
---@field agenda_filter FeyAgendaFilter
---@field filter? FeyAgendaFilter
---@field tag_filter? string
---@field category_filter? string
---@field agenda_files string | string[] | nil
---@field header? string
---@field subheader? string
---@field bufnr? number
---@field todo_only? boolean
---@field sorting_strategy? FeyAgendaSortingStrategy[]
---@field remove_tags? boolean
---@field valid_filters FeyAgendaFilter[]
---@field id? string
local FeyAgendaTodosType = {}
FeyAgendaTodosType.__index = FeyAgendaTodosType

---@param opts FeyAgendaTodosTypeOpts
function FeyAgendaTodosType:new(opts)
  local this = setmetatable({
    files = opts.files,
    highlighter = opts.highlighter,
    agenda_filter = opts.agenda_filter,
    filter = opts.filter and AgendaFilter:new():parse(opts.filter, true) or nil,
    tag_filter = opts.tag_filter and AgendaFilter:new({ types = { 'tags' } }):parse(opts.tag_filter, true) or nil,
    category_filter = opts.category_filter and AgendaFilter:new({ types = { 'categories' } })
      :parse(opts.category_filter, true) or nil,
    header = opts.header,
    subheader = opts.subheader,
    agenda_files = opts.agenda_files,
    todo_only = opts.todo_only == nil and true or opts.todo_only,
    sorting_strategy = opts.sorting_strategy or vim.tbl_get(config.fey_agenda_sorting_strategy, 'todo') or {},
    id = opts.id,
    remove_tags = type(opts.remove_tags) == 'boolean' and opts.remove_tags or config.fey_agenda_remove_tags,
  }, FeyAgendaTodosType)
  this.valid_filters = vim.tbl_filter(function(filter)
    return filter and true or false
  end, {
    this.filter,
    this.tag_filter,
    this.category_filter,
    this.agenda_filter,
  })

  this:_setup_agenda_files()
  return this
end

function FeyAgendaTodosType:prepare()
  return Promise.resolve(self)
end

function FeyAgendaTodosType:_setup_agenda_files()
  if not self.agenda_files then
    return
  end
  self.files = Files:new({
    paths = self.agenda_files,
    cache = true,
  }):load_sync(true)
end

function FeyAgendaTodosType:redo()
  if self.agenda_files then
    self.files:load_sync(true)
  end
end

function FeyAgendaTodosType:_get_header()
  if self.header then
    return self.header
  end
  return 'Global list of TODO items of type: ALL'
end

---@param bufnr? number
function FeyAgendaTodosType:render(bufnr)
  self.bufnr = bufnr or 0
  local headings, category_length = self:_get_headings()
  local agendaView = AgendaView:new({ bufnr = self.bufnr, highlighter = self.highlighter })

  -- If custom view and no headings, return empty view
  -- Works only for custom agenda views (has id)
  if self.id and config.fey_agenda_hide_empty_blocks and #headings == 0 then
    self.view = agendaView:render()
    return self.view
  end

  agendaView:add_line(AgendaLine:single_token({
    content = self:_get_header(),
    hl_group = '@fey.agenda.header',
  }))
  if self.subheader then
    agendaView:add_line(AgendaLine:single_token({
      content = self.subheader,
      hl_group = '@fey.agenda.header',
    }))
  end

  for _, heading in ipairs(headings) do
    agendaView:add_line(self:_build_line(heading, { category_length = category_length }))
  end

  self.view = agendaView:render()
  return self.view
end

---@private
---@param heading FeyHeading
---@param metadata table<string, any>
---@return FeyAgendaLine
function FeyAgendaTodosType:_build_line(heading, metadata)
  local line = AgendaLine:new({
    heading = heading,
    line_hl_group = heading:is_clocked_in() and 'Visual' or nil,
    metadata = metadata,
  })
  line:add_token(AgendaLineToken:new({
    content = '  ' .. utils.pad_right(('%s:'):format(heading:get_category()), metadata.category_length),
  }))

  local todo, _, todo_type = heading:get_todo()
  if todo then
    line:add_token(AgendaLineToken:new({
      content = todo,
      hl_group = hl_map[todo] or hl_map[todo_type],
    }))
  end
  local priority = heading:get_priority()
  if priority ~= '' then
    line:add_token(AgendaLineToken:new({
      content = ('[#%s]'):format(tostring(priority)),
      hl_group = hl_map.priority[priority].hl_group,
    }))
  end
  line:add_token(AgendaLineToken:new({
    content = heading:get_title(),
    add_markup_to_heading = heading,
  }))
  if not self.remove_tags and #heading:get_tags() > 0 then
    local tags_string = heading:tags_to_string()
    line:add_token(AgendaLineToken:new({
      content = tags_string,
      virt_text_pos = 'right_align',
      hl_group = '@fey.agenda.tag',
    }))
  end
  return line
end

---@return FeyAgendaLine[]
function FeyAgendaTodosType:get_lines()
  return self.view.lines
end

---@param row number
---@return FeyAgendaLine | nil
function FeyAgendaTodosType:get_line(row)
  return utils.find(self.view.lines, function(line)
    return line.line_nr == row
  end)
end

---@param agenda_line FeyAgendaLine
---@param heading FeyHeading
function FeyAgendaTodosType:rerender_agenda_line(agenda_line, heading)
  local line = self:_build_line(heading, agenda_line.metadata)
  self.view:replace_line(agenda_line, line)
end

---@param file FeyFile
---@return FeyHeading[]
function FeyAgendaTodosType:get_file_headings(file)
  if self.todo_only then
    return file:get_unfinished_todo_entries()
  end

  return file:get_headings()
end

---@return FeyHeading[], number
function FeyAgendaTodosType:_get_headings()
  local items = {}
  local category_length = 0

  for _, feyfile in ipairs(self.files:all()) do
    local headings = self:get_file_headings(feyfile)
    for i, heading in ipairs(headings) do
      if self:_matches_filters(heading) then
        category_length = math.max(category_length, vim.api.nvim_strwidth(heading:get_category()))
        ---@diagnostic disable-next-line: inject-field
        heading.index = i
        table.insert(items, heading)
      end
    end
  end

  self:_sort(items)
  return items, category_length + 1
end

function FeyAgendaTodosType:_matches_filters(heading)
  for _, filter in ipairs(self.valid_filters) do
    if filter and not filter:matches(heading) then
      return false
    end
  end
  return true
end

---@private
---@param todos FeyHeading[]
---@return FeyHeading[]
function FeyAgendaTodosType:_sort(todos)
  ---@param heading FeyHeading
  local make_entry = function(heading)
    return {
      heading = heading,
      index = heading.index,
      is_day_match = false,
    }
  end
  return SortingStrategy.sort(todos, self.sorting_strategy, make_entry)
end

return FeyAgendaTodosType
