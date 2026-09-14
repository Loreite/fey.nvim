---@class FeyBabel
local Babel = {}
local Tangle = require('fey.babel.tangle')

---@param file FeyFile
function Babel.tangle(file)
  return Tangle:new({ file = file }):tangle()
end

return Babel
