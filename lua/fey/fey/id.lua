local config = require('fey.config')
local utils = require('fey.utils')

local FeyId = {
  uuid_pattern = '%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x',
}

---@return string
function FeyId.new()
  return FeyId._generate()
end

---@return boolean
function FeyId.is_valid_uuid(value)
  if not value or vim.trim(value) == '' then
    return false
  end

  return value:match(FeyId.uuid_pattern) ~= nil
end

---@private
---@return string
function FeyId._generate()
  if config.fey_id_method == 'uuid' then
    if vim.fn.executable(config.fey_id_uuid_program) ~= 1 then
      utils.echo_error('fey_id_uuid_program is not executable: ' .. config.fey_id_uuid_program)
      return ''
    end
    return tostring(vim.fn.system(config.fey_id_uuid_program):gsub('%s+', ''))
  end

  if config.fey_id_method == 'ts' then
    return tostring(os.date(config.fey_id_ts_format))
  end

  if config.fey_id_method == 'fey' then
    math.randomseed(os.clock() * 100000000000)
    return ('%s%s'):format(vim.trim(config.fey_id_prefix or ''), math.random(100000000000000))
  end

  utils.echo_error('Invalid fey_id_method: ' .. config.fey_id_method)
  return ''
end

return FeyId
