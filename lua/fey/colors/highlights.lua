local config = require('fey.config')
local colors = require('fey.colors')
local utils = require('fey.utils')
local M = {}

function M.define_highlights()
  M.link_highlights()
  M.define_agenda_colors()
  M.define_fey_todo_keyword_colors()
  M.define_todo_keyword_faces()
end

function M.link_highlights()
  local links = {
    -- Headings
    ['@fey.heading.level1'] = 'Title',
    ['@fey.heading.level2'] = 'Constant',
    ['@fey.heading.level3'] = 'Identifier',
    ['@fey.heading.level4'] = 'Statement',
    ['@fey.heading.level5'] = 'PreProc',
    ['@fey.heading.level6'] = 'Type',
    ['@fey.heading.level7'] = 'Special',
    ['@fey.heading.level8'] = 'String',

    ['@fey.priority.highest'] = '@comment.error',

    -- Heading tags
    ['@fey.tag'] = '@tag.attribute',

    -- Heading plan
    ['@fey.plan'] = 'Constant',

    -- Timestamps
    ['@fey.timestamp.active'] = '@keyword',
    ['@fey.timestamp.inactive'] = '@comment',
    -- Lists/Checkboxes
    ['@fey.bullet'] = '@markup.list',
    ['@fey.checkbox'] = '@markup.list.unchecked',
    ['@fey.checkbox.halfchecked'] = '@markup.list.unchecked',
    ['@fey.checkbox.checked'] = '@markup.list.checked',

    -- Drawers
    ['@fey.properties'] = '@property',
    ['@fey.properties.name'] = '@property',
    ['@fey.drawer'] = '@property',

    ['@fey.comment'] = '@comment',
    ['@fey.directive'] = '@comment',
    ['@fey.block'] = '@comment',

    -- Markup
    ['@fey.bold'] = '@markup.strong',
    ['@fey.bold.delimiter'] = '@markup.strong',
    ['@fey.italic'] = '@markup.italic',
    ['@fey.italic.delimiter'] = '@markup.italic',
    ['@fey.strikethrough'] = '@markup.strikethrough',
    ['@fey.strikethrough.delimiter'] = '@markup.strikethrough',
    ['@fey.underline'] = '@markup.underline',
    ['@fey.underline.delimiter'] = '@markup.underline',
    ['@fey.code'] = '@markup.raw',
    ['@fey.code.delimiter'] = '@markup.raw',
    ['@fey.verbatim'] = '@markup.raw',
    ['@fey.verbatim.delimiter'] = '@markup.raw',
    ['@fey.hyperlink'] = '@markup.link',
    ['@fey.hyperlink.url'] = '@markup.link.url',
    ['@fey.hyperlink.desc'] = '@markup.link.label',
    ['@fey.latex'] = '@markup.math',
    ['@fey.latex_env'] = '@markup.environment',
    ['@fey.footnote'] = '@markup.link.url',
    ['@fey.footnote.reference'] = '@markup.link.url',
    -- Other
    ['@fey.table.delimiter'] = '@punctuation.special',
    ['@fey.table.heading'] = '@markup.heading',
    ['@fey.edit_src'] = 'Visual',
  }

  for src, def in pairs(links) do
    if type(def) == 'table' then
      def.default = true
      vim.api.nvim_set_hl(0, src, def)
    else
      vim.api.nvim_set_hl(0, src, { link = def, default = true })
    end
  end
end

function M.define_agenda_colors()
  local keyword_colors = colors.get_todo_keywords_colors()
  local c = {
    deadline = '@fey.agenda.deadline',
    upcoming_deadline = '@fey.agenda.deadline.upcoming',
    ok = '@fey.agenda.scheduled',
    warning = '@fey.agenda.scheduled_past',
  }
  for type, hlname in pairs(c) do
    vim.cmd(string.format('hi default %s guifg=%s ctermfg=%s', hlname, keyword_colors[type].gui, keyword_colors[type].cterm))
  end
  vim.cmd(
    ('hi default @fey.agenda.time_grid guifg=%s ctermfg=%s'):format(keyword_colors.warning.gui, keyword_colors.warning.cterm)
  )

  M.define_fey_todo_keyword_colors()
end

function M.define_fey_todo_keyword_colors()
  local keyword_colors = colors.get_todo_keywords_colors()
  vim.cmd(
    ('hi default @fey.keyword.todo guifg=%s ctermfg=%s gui=bold cterm=bold'):format(
      keyword_colors.TODO.gui,
      keyword_colors.TODO.cterm
    )
  )

  vim.cmd(
    ('hi default @fey.keyword.done guifg=%s ctermfg=%s gui=bold cterm=bold'):format(
      keyword_colors.DONE.gui,
      keyword_colors.DONE.cterm
    )
  )
  vim.cmd([[hi default @fey.leading_signature ctermfg=0 guifg=bg]])
end

function M.define_todo_keyword_faces()
  local opts = {
    underline = {
      type = vim.o.termguicolors and 'gui' or 'cterm',
      is_valid = function(value)
        return value == 'on'
      end,
      result = 'underline',
    },
    weight = {
      type = vim.o.termguicolors and 'gui' or 'cterm',
      is_valid = function(value)
        return value == 'bold'
      end,
    },
    foreground = {
      type = vim.o.termguicolors and 'guifg' or 'ctermfg',
      is_valid = function(value)
        if vim.o.termguicolors then
          return true
        end
        return value:sub(1, 1) ~= '#'
      end,
    },
    background = {
      type = vim.o.termguicolors and 'guibg' or 'ctermbg',
      is_valid = function(value)
        if vim.o.termguicolors then
          return true
        end
        return value:sub(1, 1) ~= '#'
      end,
    },
    slant = {
      type = vim.o.termguicolors and 'gui' or 'cterm',
      is_valid = function(value)
        return value == 'italic'
      end,
    },
  }

  local result = {}

  for name, values in pairs(config.fey_todo_keyword_faces) do
    local parts = vim.split(values, ':', { plain = true })
    local hl_opts = {}
    for _, part in ipairs(parts) do
      local faces = vim.split(vim.trim(part), ' ')
      if #faces == 2 then
        local opt_name = vim.trim(faces[1])
        local opt_value = vim.trim(faces[2])
        opt_value = opt_value:gsub('^"*', ''):gsub('"*$', '')
        local opt = opts[opt_name]
        if opt and opt.is_valid(opt_value) then
          if not hl_opts[opt.type] then
            hl_opts[opt.type] = {}
          end
          table.insert(hl_opts[opt.type], opt.result or opt_value)
        end
      end
    end
    if not vim.tbl_isempty(hl_opts) then
      local hl_name = '@fey.keyword.face.' .. name:gsub('%-', '')
      local hl = ''
      for hl_item, hl_values in pairs(hl_opts) do
        hl = hl .. ' ' .. hl_item .. '=' .. table.concat(hl_values, ',')
      end
      vim.cmd(string.format('hi default %s %s', hl_name, hl))
      result[name] = hl_name
    end
  end

  return result
end

---@return table<string, string>
function M.get_agenda_hl_map()
  local faces = M.define_todo_keyword_faces()
  return vim.tbl_extend('force', {
    TODO = '@fey.keyword.todo',
    DONE = '@fey.keyword.done',
    deadline = '@fey.agenda.deadline',
    upcoming_deadline = '@fey.agenda.deadline.upcoming',
    ok = '@fey.agenda.scheduled',
    warning = '@fey.agenda.scheduled_past',
    priority = config:get_priorities(),
  }, faces)
end

return M
