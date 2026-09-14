local Events = require('fey.events.types')
local AlignTags = require('fey.events.listeners.align_tags')
local ClockOut = require('fey.events.listeners.clock_out')
local Reindex = require('fey.events.listeners.reindex')

return {
  [Events.TodoChanged] = {
    AlignTags,
    ClockOut,
  },
  [Events.HeadingDemoted] = {
    AlignTags,
    Reindex,
  },
  [Events.HeadingPromoted] = {
    AlignTags,
    Reindex,
  },
  [Events.HeadingMoved] = {
    Reindex,
  },
  [Events.BufferChanged] = {
    Reindex,
  },
}
