---@class FeyEvent
---@field type string

return {
  TodoChanged = require('fey.events.types.todo_changed_event'),
  HeadingPromoted = require('fey.events.types.heading_promoted_event'),
  HeadingDemoted = require('fey.events.types.heading_demoted_event'),
  HeadingMoved = require('fey.events.types.heading_moved_event'),
  HeadingToggled = require('fey.events.types.heading_toggled'),
  NoteAdded = require('fey.events.types.note_added_event'),
  ClockedIn = require('fey.events.types.clocked_in'),
  ClockedOut = require('fey.events.types.clocked_out'),
}
