-- How a tag of your own is written in an export, and which tag names are HTML elements.
--
-- An export is a pattern for each form of the tag; `%s` is where what the tag holds goes (the HTML for the HTML target, the Markdown for the
-- Markdown target, so the wrapper is HTML embedded in the Markdown), `%%` is a percent sign and `\n` a new line:
--
--   require('fey').setup({
--     tag_exports = {
--       note = {
--         block_tag = [[<aside class="note">\n%s\n</aside>]],
--         pair_tag = [[<aside class="note">\n%s\n</aside>]],
--         line_tag = [[<span class="note">%s</span>]],
--         scope_tag = [[<div class="note">\n%s\n</div>]],   -- wraps what the tag applies to: the paragraph, the list, the item, the section text
--       },
--     },
--   })
--
-- A form may also be a function `function(body, tag, target)` that returns the text (`tag` is `{ name, form, values, keys }`, `target` is
-- `'html'` or `'markdown'`); returning nil leaves the default. One string or function instead of the table is the same for every form, a table
-- with the keys `html` and `markdown` gives each target its own forms (Markdown falls back to the HTML ones, which it can embed), and a form
-- named `default` is the one of the forms that are not there.
--
-- Names: a tag you gave an export (or an editor handler, or that the plugin has) keeps that meaning. For the HTML element of the same name
-- write the name with a trailing underscore: the weaker of two names ends with `_`. With a `div` of your own, `div_` is the HTML `div`, and
-- `section_` is the HTML `section` where `section` is the link to a heading. An element whose name nothing else uses (`span`, `mark`, `kbd`)
-- needs no underscore.
local config = require('fey.config')

local M = {}

---@type table<string, table|string|function> the exports added at run time, see `M.add`
M.registry = {}

---Give a tag an export
---@param name string
---@param spec table|string|function
function M.add(name, spec) M.registry[name] = spec end

---The export of a tag name, if it has one
---@param name string
---@return table|string|function|nil
function M.lookup(name)
  local from_config = config.tag_exports and config.tag_exports[name]
  if from_config ~= nil then return from_config end
  return M.registry[name]
end

---The pattern or function for a form of a tag
---@param spec table|string|function
---@param form string scope_tag|line_tag|block_tag|pair_tag
---@param target 'html'|'markdown'
---@return string|function|nil
function M.resolve(spec, form, target)
  if type(spec) == 'string' or type(spec) == 'function' then return spec end
  if type(spec) ~= 'table' then return nil end
  local per = spec[target]
  if per == nil and target == 'markdown' then per = spec.html end
  if per == nil and spec.html == nil and spec.markdown == nil then per = spec end
  if type(per) == 'string' or type(per) == 'function' then return per end
  if type(per) ~= 'table' then return nil end
  local value = per[form]
  if value == nil then value = per.default end
  return value
end

---Put a body in a pattern
---@param pattern string
---@param body string
---@return string
function M.fill(pattern, body)
  pattern = pattern:gsub('\\n', '\n')
  local out, i, done = {}, 1, false
  while i <= #pattern do
    local two = pattern:sub(i, i + 1)
    if two == '%%' then
      out[#out + 1] = '%'
      i = i + 2
    elseif two == '%s' and not done then
      out[#out + 1] = body
      done = true
      i = i + 2
    else
      out[#out + 1] = pattern:sub(i, i)
      i = i + 1
    end
  end
  return table.concat(out)
end

---The text of a tag with its body in it, or nil when the tag has no export for that form and target
---@param spec table|string|function
---@param tag { name: string, form: string, values: string[], keys: table<string, string> }
---@param body string
---@param target 'html'|'markdown'
---@return string|nil
function M.render(spec, tag, body, target)
  local value = M.resolve(spec, tag.form, target)
  if type(value) == 'function' then
    local ok, result = pcall(value, body, tag, target)
    if ok and type(result) == 'string' then return result end
    return nil
  end
  if type(value) == 'string' then return M.fill(value, body) end
  return nil
end

-- the elements a tag name can stand for (a broad list: nothing that runs code or loads things)
M.HTML_ELEMENTS = {}
for _, name in ipairs({
  'span', 'mark', 'kbd', 'sub', 'sup', 'abbr', 'small', 'u', 's', 'cite', 'q', 'time', 'del', 'ins', 'dfn', 'var', 'samp', 'bdi', 'wbr',
  'em', 'strong', 'code', 'i', 'b',
  'div', 'details', 'summary', 'blockquote', 'aside', 'figure', 'figcaption', 'article', 'nav', 'header', 'footer', 'address', 'center',
  'section', 'p', 'pre', 'ul', 'ol', 'li', 'table', 'thead', 'tbody', 'tr', 'td', 'th', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
}) do
  M.HTML_ELEMENTS[name] = true
end

---Is a tag name taken: by the plugin, by an export, by a handler of the editor
---@param name string
---@param plugin_kind fun(name: string): any the exporter's own kinds
---@return boolean
function M.taken(name, plugin_kind)
  if plugin_kind(name) ~= nil then return true end
  if M.lookup(name) ~= nil then return true end
  local handlers = require('fey.files.elements.tags').handlers
  return handlers ~= nil and handlers[name] ~= nil
end

---The HTML element a tag name stands for: `name_` is the element `name`; the name itself is the element when nothing else has it
---@param name string
---@param plugin_kind fun(name: string): any
---@return string|nil element
function M.html_element(name, plugin_kind)
  if name:sub(-1) == '_' then
    local base = name:sub(1, -2)
    return M.HTML_ELEMENTS[base] and base or nil
  end
  if M.HTML_ELEMENTS[name] and not M.taken(name, plugin_kind) then return name end
  return nil
end

return M
