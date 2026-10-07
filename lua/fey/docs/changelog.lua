-- The changelog of the docs, from the history of the repository since the last release of the plugin as it was before Fey. It changes with every commit,
-- so `scripts/gen_docs.lua --check` leaves it alone.
local M = {}

---@return string[]
function M.render()
  local function git(args)
    local result = vim.system(vim.list_extend({ 'git' }, args), { text = true }):wait()
    return result.code == 0 and vim.trim(result.stdout) or ''
  end
  local tag = git({ 'describe', '--tags', '--abbrev=0' })
  local range = tag ~= '' and (tag .. '..HEAD') or 'HEAD'
  local log = git({ 'log', range, '--pretty=format:%s%x09%h' })
  local features, fixes, others = {}, {}, {}
  for line in vim.gsplit(log, '\n', { plain = true, trimempty = true }) do
    local subject, hash = line:match('^(.-)\t(%x+)$')
    if subject then
      local item = ('%s (%s)'):format(require('fey.docs.generated').prose(subject), hash)
      if subject:match('^feat') then
        features[#features + 1] = item
      elseif subject:match('^fix') then
        fixes[#fixes + 1] = item
      else
        others[#others + 1] = item
      end
    end
  end
  local out = {}
  local function section(name, items)
    if #items == 0 then return end
    out[#out + 1] = name .. ':'
    out[#out + 1] = ''
    for _, item in ipairs(items) do
      out[#out + 1] = '-  ' .. item
    end
    out[#out + 1] = ''
  end
  out[#out + 1] = tag ~= '' and ('Since %s, the last release before Fey:'):format(tag) or 'Since the start:'
  out[#out + 1] = ''
  section('Features', features)
  section('Fixes', fixes)
  section('Changes', others)
  if #features + #fixes + #others == 0 then out[#out + 1] = 'No changes yet.' end
  return out
end

return M
