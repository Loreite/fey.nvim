local config = require('fey.config')
local Promise = require('fey.utils.promise')
local utils = require('fey.utils')

---@class FeyInput
local FeyInput = {}

---@param prompt string
---@param default? string
---@param completion? string | fun(arg_lead: string): string[]
---@return FeyPromise<string>
function FeyInput.open(prompt, default, completion)
  _G.fey.__input_completion = completion
  local opts = {
    prompt = prompt,
    default = default or '',
  }
  if type(completion) == 'string' then
    opts.completion = completion
  elseif completion then
    opts.completion = 'customlist,v:lua.fey.__input_completion'
  end

  return Promise.new(function(resolve, reject)
    if config.ui.input.use_vim_ui then
      return vim.ui.input(opts, function(value)
        if value == nil then
          return reject('Canceled')
        end
        return resolve(value)
      end)
    end

    opts.cancelreturn = vim.NIL
    local value = vim.fn.input(opts)
    if value == vim.NIL then
      return reject('Canceled')
    end
    return resolve(value)
  end):catch(function()
    utils.echo_error('Input canceled')
  end)
end

return FeyInput
