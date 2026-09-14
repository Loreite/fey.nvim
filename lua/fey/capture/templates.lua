local config = require('fey.config')
local Template = require('fey.capture.template')

---@see https://fey.fey/manual/Capture-templates.html

---@class FeyCaptureTemplates
---@field templates table<string, FeyCaptureTemplate>
local Templates = {}

---@param templates? table<string, FeyCaptureTemplate>
---@return FeyCaptureTemplates
function Templates:new(templates)
  local opts = {}

  vim.validate('templates', templates, 'table', true)

  opts.templates = {}
  for key, template in pairs(templates or config.fey_capture_templates) do
    if type(template) == 'table' then
      local tpl = vim.deepcopy(template)
      if not tpl.target then
        tpl.target = config.fey_default_notes_file
      end
      opts.templates[key] = Template:new(tpl)
    else
      opts.templates[key] = template
    end
  end

  setmetatable(opts, self)
  self.__index = self
  return opts
end

function Templates:get_list()
  return self.templates
end

return Templates
