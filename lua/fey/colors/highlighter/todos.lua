local highlights = require('fey.colors.highlights')
local utils = require('fey.utils')
local Promise = require('fey.utils.promise')
local tree_utils = require('fey.utils.treesitter')

---@class FeyTodosHighlighter
local FeyTodos = {}

function FeyTodos:new()
  local data = {}
  setmetatable(data, self)
  self.__index = self
  data:_add_highlights()
  return data
end

function FeyTodos:_add_highlights()
  local query_files = vim.treesitter.query.get_files('fey', 'highlights')
  if not query_files or #query_files == 0 then
    return
  end
  local faces = highlights.define_todo_keyword_faces()
  if not faces or vim.tbl_isempty(faces) then
    return
  end

  local actions = {}
  for i, _ in pairs(query_files) do
    if i ~= #query_files then
      table.insert(actions, utils.readfile(query_files[i]))
    else
      table.insert(
        actions,
        utils.readfile(query_files[i]):next(function(lines)
          for face_name, face_hl in pairs(faces) do
            table.insert(lines, string.format([[(item . (expr) %s @nospell (#eq? %s %s))]], face_hl, face_hl, face_name))
          end
          return lines
        end)
      )
    end
  end

  return Promise.all(actions):next(vim.schedule_wrap(function(line_parts)
    local all_lines = {}
    for _, line_part in ipairs(line_parts) do
      utils.concat(all_lines, line_part)
    end
    vim.treesitter.query.set('fey', 'highlights', table.concat(all_lines, '\n'))
    if vim.bo.filetype == 'fey' then
      tree_utils.restart_highlights()
    end
  end))
end

return FeyTodos
