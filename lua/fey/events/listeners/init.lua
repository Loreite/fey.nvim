local Events = require('fey.events.types')
local ClockOut = require('fey.events.listeners.clock_out')
local Reindex = require('fey.events.listeners.reindex')

return {
  [Events.TodoChanged] = {
    ClockOut,
  },
  [Events.HeadingDemoted] = {
    Reindex,
  },
  [Events.HeadingPromoted] = {
    Reindex,
  },
  [Events.HeadingMoved] = {
    Reindex,
  },
  [Events.BufferChanged] = {
    Reindex,
  },
}
