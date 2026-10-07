-- Tangling: the source blocks that have a `:tangle` header argument are written to files.
--
--   ###  src lua :tangle out.lua :noweb yes
--   print('hi')
--   <<helper>>
--   ###
--
-- The planning is separate from the writing, so it can be checked without writing anything (`Tangle.plan`):
--
--   * blocks with the same target are written one after the other with a blank line between them
--   * a line that is only `<<name>>` is replaced by the blocks named `name` (the header argument `:name`, or `:noweb-ref`) of
--     the same file when the block has `:noweb yes` (or `tangle`); the indent of the line goes to what replaces it
--   * `<<name>>` that names no block, blocks that refer to each other, and one target written by blocks of two files
--     are problems; a target with a conflict is not written
--
-- The target is `yes` (the file with the extension of the language), or a path: `~/..` and absolute paths as they
-- are, any other relative to the directory of the file.
local utils = require('fey.utils')
local Promise = require('fey.utils.promise')

---@class FeyTangleInfo
---@field file string absolute path of the file the block is in
---@field line integer line of the block
---@field name? string
---@field language? string
---@field tangle? string `:tangle` as written
---@field noweb boolean
---@field mkdirp boolean
---@field content string[]

---@class FeyTangleProblem
---@field kind 'unresolved'|'cycle'|'conflict'
---@field file string
---@field line integer
---@field message string

---@class FeyTangleBabel
---@field targets table<string, string[]> the lines of every target
---@field order string[] the targets in the order they first appear
---@field mkdirp table<string, boolean>
---@field problems FeyTangleProblem[]
---@field count integer blocks written

local Tangle = {}
Tangle.__index = Tangle

---@param opts { file: FeyFile }
---@return FeyBabelTangle
function Tangle:new(opts) return setmetatable({ file = opts.file }, self) end

---The file extension of a language, the name of the language when it has no entry here (`fey_babel_extensions` adds some)
Tangle.EXTENSIONS = {
  python = 'py', javascript = 'js', typescript = 'ts', rust = 'rs', ruby = 'rb', bash = 'sh', sh = 'sh', zsh = 'sh',
  markdown = 'md', latex = 'tex', tex = 'tex', csharp = 'cs', haskell = 'hs', perl = 'pl', kotlin = 'kt', vim = 'vim',
  cpp = 'cpp', c = 'c', yaml = 'yaml', javascriptreact = 'jsx', typescriptreact = 'tsx', fey = 'fey',
}

---@param language string
---@return string
function Tangle.extension(language)
  local custom = require('fey.config').fey_babel_extensions or {}
  return custom[language] or Tangle.EXTENSIONS[language] or language
end

---Where a block is written
---@param tangle string|nil the header argument
---@param language string|nil
---@param file string absolute path of the file the block is in
---@return string|nil filename nil when the block is not tangled
function Tangle.target(tangle, language, file)
  if not tangle or tangle == '' or tangle == 'no' then return nil end
  if tangle == 'yes' then return vim.fn.fnamemodify(file, ':p:r') .. (language and ('.' .. Tangle.extension(language)) or '') end
  if tangle:match('^~') then return vim.fn.expand(tangle) end
  if tangle:match('^/') then return tangle end
  return vim.fs.normalize(vim.fn.fnamemodify(file, ':p:h') .. '/' .. tangle)
end

---Take the indent the whole block has off its lines (a block in a list item is indented)
---@param lines string[]
---@return string[]
function Tangle.dedent(lines)
  local amount
  for _, line in ipairs(lines) do
    if vim.trim(line) ~= '' then
      local indent = #line:match('^%s*')
      amount = amount and math.min(amount, indent) or indent
    end
  end
  if not amount or amount == 0 then return lines end
  return vim.tbl_map(function(line) return line:sub(amount + 1) end, lines)
end

---Plan the writing of blocks: expand the references, group by target, find the problems
---@param infos FeyTangleInfo[] in the order of the files and of the lines of the blocks
---@return FeyTangleBabel
function Tangle.plan(infos)
  local plan = { targets = {}, order = {}, mkdirp = {}, problems = {}, count = 0 }
  local owner = {} -- target -> file that writes it

  -- the blocks of a name, by file
  local named = {}
  for _, info in ipairs(infos) do
    if info.name then
      named[info.file] = named[info.file] or {}
      named[info.file][info.name] = named[info.file][info.name] or {}
      table.insert(named[info.file][info.name], info)
    end
  end

  local function problem(kind, info, message)
    table.insert(plan.problems, { kind = kind, file = info.file, line = info.line, message = message })
  end

  ---@param info FeyTangleInfo the block that is written
  ---@param content string[]
  ---@param stack string[] names being expanded
  ---@return string[]
  local function expand(info, content, stack)
    local out = {}
    for _, line in ipairs(content) do
      local indent, ref = line:match('^(%s*)<<(.-)>>%s*$')
      if not ref then
        out[#out + 1] = line
      else
        local blocks = named[info.file] and named[info.file][ref]
        if not blocks then
          problem('unresolved', info, ('<<%s>> names no block'):format(ref))
          out[#out + 1] = line
        elseif vim.tbl_contains(stack, ref) then
          problem('cycle', info, ('<<%s>> refers to itself: %s'):format(ref, table.concat(stack, ' > ')))
        else
          local inner = vim.list_extend({ unpack(stack) }, { ref })
          for _, block in ipairs(blocks) do
            for _, l in ipairs(expand(info, block.content, inner)) do
              out[#out + 1] = l == '' and l or (indent .. l)
            end
          end
        end
      end
    end
    return out
  end

  local conflicted = {}
  for _, info in ipairs(infos) do
    local filename = Tangle.target(info.tangle, info.language, info.file)
    if filename then
      if owner[filename] and owner[filename] ~= info.file then
        conflicted[filename] = true
        problem('conflict', info, ('%s is also written by %s'):format(filename, owner[filename]))
      else
        owner[filename] = info.file
        local content = info.noweb and expand(info, info.content, info.name and { info.name } or {}) or info.content
        if plan.targets[filename] then
          table.insert(plan.targets[filename], '')
        else
          plan.targets[filename] = {}
          table.insert(plan.order, filename)
        end
        vim.list_extend(plan.targets[filename], content)
        if info.mkdirp then plan.mkdirp[filename] = true end
        plan.count = plan.count + 1
      end
    end
  end
  for filename in pairs(conflicted) do
    plan.targets[filename] = nil
    plan.order = vim.tbl_filter(function(f) return f ~= filename end, plan.order)
  end
  return plan
end

---Write a plan
---@param plan FeyTangleBabel
---@return integer written files
function Tangle.write(plan)
  local promises = {}
  for _, filename in ipairs(plan.order) do
    if plan.mkdirp[filename] then vim.fn.mkdir(vim.fn.fnamemodify(filename, ':h'), 'p') end
    table.insert(promises, utils.writefile(filename, table.concat(plan.targets[filename], '\n')))
  end
  Promise.all(promises):wait()
  return #plan.order
end

---The infos of the source blocks of a file
---@param file FeyFile
---@return FeyTangleInfo[]
function Tangle.infos_of_file(file)
  local infos = {}
  for _, block in ipairs(file:get_blocks()) do
    if block:is_src_block() then
      local info = block:get_tangle_info()
      table.insert(infos, {
        file = vim.fn.fnamemodify(file.filename, ':p'),
        line = (block.node:start()) + 1,
        name = info.name,
        language = block:get_language(),
        tangle = info.header_args[':tangle'],
        noweb = info.header_args[':noweb'] == 'yes' or info.header_args[':noweb'] == 'tangle',
        mkdirp = info.header_args[':mkdirp'] == 'yes',
        content = Tangle.dedent(info.content),
      })
    end
  end
  return infos
end

---The infos of the rows of `FeyVault:blocks` (with `abs`)
---@param rows table[]
---@return FeyTangleInfo[]
function Tangle.infos_of_rows(rows)
  local config = require('fey.config')
  local defaults = config.fey_babel_default_header_args
  local infos = {}
  for _, row in ipairs(rows) do
    if row.kind == 'src' then
      local args = vim.tbl_extend('force', defaults, row.args or {})
      local noweb = args[':noweb']
      table.insert(infos, {
        file = row.abs,
        line = row.line,
        name = row.name,
        language = row.language and config:detect_filetype(row.language, true) or nil,
        tangle = args[':tangle'],
        noweb = noweb == 'yes' or noweb == 'tangle',
        mkdirp = args[':mkdirp'] == 'yes',
        content = Tangle.dedent(vim.split(row.content or '', '\n', { plain = true })),
      })
    end
  end
  return infos
end

---Tangle the blocks of one file
function Tangle:tangle()
  local plan = Tangle.plan(Tangle.infos_of_file(self.file))
  Tangle.write(plan)
  for _, p in ipairs(plan.problems) do
    utils.echo_warning(('%s:%d: %s'):format(vim.fn.fnamemodify(p.file, ':t'), p.line, p.message))
  end
  utils.echo_info(('Tangled %d blocks from %s'):format(plan.count, vim.fn.fnamemodify(self.file.filename, ':t')))
  return plan
end

return Tangle
