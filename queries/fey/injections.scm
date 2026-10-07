(block parameter: (expr) @_lang (contents) @injection.content (#set! injection.include-children) (#fey-set-block-language! @_lang))
; (inline_code_block
;   open: (open) @_lang
;   contents: (contents) @injection.content
;   (#set! injection.include-children)
;   (#fey-set-inline-block-language! @_lang))
; (latex_env (contents) @injection.content (#set! injection.include-children) (#set! injection.language "tex"))

; math: the text of a line, block or pair tag named `fey_math_tag_name` is LaTeX
(line_tag
  name: (tag_name) @_name
  (body) @injection.content
  (#fey-is-math-tag? @_name)
  (#set! injection.language "latex")
  (#set! injection.include-children))
(block_tag
  name: (tag_name) @_name
  body: (body) @injection.content
  (#fey-is-math-tag? @_name)
  (#set! injection.language "latex")
  (#set! injection.include-children))
(pair_tag
  open: (pair_open name: (tag_name) @_name)
  body: (body) @injection.content
  (#fey-is-math-tag? @_name)
  (#set! injection.language "latex")
  (#set! injection.include-children))
