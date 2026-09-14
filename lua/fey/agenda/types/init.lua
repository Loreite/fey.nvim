---@class FeyAgendaViewType
---@field render fun(self: FeyAgendaViewType, bufnr:number, current_line?: number): FeyAgendaView
---@field get_lines fun(self: FeyAgendaViewType): FeyAgendaLine | FeyAgendaLine[]
---@field get_line fun(self: FeyAgendaViewType, line_nr: number): FeyAgendaLine | nil
---@field rerender_agenda_line fun(self: FeyAgendaViewType, agenda_line: FeyAgendaLine, heading: FeyHeading): FeyAgendaLine | nil
---@field view FeyAgendaView
---@field prepare fun(self: FeyAgendaViewType): FeyPromise<FeyAgendaViewType>
---@field redraw? fun(self: FeyAgendaViewType): FeyPromise<FeyAgendaViewType>
---@field redo? fun(self: FeyAgendaViewType): FeyPromise<FeyAgendaViewType>

---@alias FeyAgendaTypes 'agenda' | 'todo' | 'tags' | 'tags_todo' | 'search'
return {
  agenda = require('fey.agenda.types.agenda'),
  todo = require('fey.agenda.types.todo'),
  tags = require('fey.agenda.types.tags'),
  tags_todo = require('fey.agenda.types.tags_todo'),
  search = require('fey.agenda.types.search'),
}
