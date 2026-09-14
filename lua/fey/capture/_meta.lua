---@meta

---@class FeyProcessRefileOpts
---@field source_heading FeyHeading
---@field destination_file? FeyFile
---@field destination_heading? FeyHeading
---@field message? string

---@class FeyProcessCaptureOpts
---@field template FeyCaptureTemplate
---@field capture_window FeyCaptureWindow
---@field source_file FeyFile
---@field source_heading? FeyHeading
---@field destination_file FeyFile
---@field destination_heading? FeyHeading

---@class FeyDatetreeTreeItem
---@field format string - The lua date format to use for the tree item
---@field pattern string - Pattern to match important date parts the date format
---@field order number[] - Order of checking the date parts matched from the pattern

---@class FeyCaptureTemplateDatetreeOpts
---@field date FeyDate
---@field time_prompt? boolean
---@field reversed? boolean
---@field tree? FeyDatetreeTreeItem[]
---@field tree_type? 'day' | 'week' | 'month' | 'custom'

---@alias FeyCaptureTemplateDatetree boolean | FeyCaptureTemplateDatetreeOpts
