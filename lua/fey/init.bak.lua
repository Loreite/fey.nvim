local M = {}

local sequences = require('fey.sequences')

function M.setup()
  vim.api.nvim_create_autocmd('FileType', {
    pattern = 'fey',
    callback = function(args)
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(args.buf) then
          pcall(vim.treesitter.start, args.buf, 'fey')
        end
      end)

      local opts = { buffer = args.buf, silent = true }

      vim.keymap.set('n', '<leader>;j', function()
        M.move_subtree('down')
      end, opts)
      vim.keymap.set('n', '<leader>;k', function()
        M.move_subtree('up')
      end, opts)

      vim.keymap.set('n', '<leader>;H', function()
        M.change_subtree_depth('promote')
      end, opts)
      vim.keymap.set('n', '<leader>;L', function()
        M.change_subtree_depth('demote')
      end, opts)

      vim.keymap.set('n', '<leader>;h', function()
        M.change_depth('promote')
      end, opts)
      vim.keymap.set('n', '<leader>;l', function()
        M.change_depth('demote')
      end, opts)

      local augroup = vim.api.nvim_create_augroup('FeyAutoReindex_' .. args.buf, { clear = true })
    end,
  })
end

vim.treesitter.query.add_predicate('fey-is-heading-level?', function(match, _, source, predicate)
  if type(source) == 'number' and not vim.api.nvim_buf_is_loaded(source) then
    return false
  end
  local node = match[predicate[2]]
  node = node and node[#node]
  if not node then
    return false
  end

  local target_level = tonumber(predicate[3])
  local text = vim.treesitter.get_node_text(node, source)
  local _, count = text:gsub('[.,:;/\\!?\'"%-+*=@&#$%%]', '')

  return ((count - 1) % 8) + 1 == target_level
end, { force = true, all = true })

return M
