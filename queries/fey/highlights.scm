;; Level-based heading highlighting using a custom predicate matcher
(heading (signature) @signature (#fey-is-heading-level? @signature "1")) @fey.heading.level1
(heading (signature) @signature (#fey-is-heading-level? @signature "2")) @fey.heading.level2
(heading (signature) @signature (#fey-is-heading-level? @signature "3")) @fey.heading.level3
(heading (signature) @signature (#fey-is-heading-level? @signature "4")) @fey.heading.level4
(heading (signature) @signature (#fey-is-heading-level? @signature "5")) @fey.heading.level5
(heading (signature) @signature (#fey-is-heading-level? @signature "6")) @fey.heading.level6
(heading (signature) @signature (#fey-is-heading-level? @signature "7")) @fey.heading.level7
(heading (signature) @signature (#fey-is-heading-level? @signature "8")) @fey.heading.level8

; general
(body (paragraph) @spell)

; lists
(list (listitem (paragraph) @spell))
(bullet) @fey.bullet
(checkbox) @fey.checkbox
((checkbox) @fey.checkbox.checked (#match? @fey.checkbox.checked "\\[[xX]\\]"))
((checkbox) @fey.checkbox.halfchecked (#match? @fey.checkbox.halfchecked "\\[/\\]"))

; blocks
(block [ (fence) (expr) ] @fey.block)

; ---- tags -------------------------------------------------------------------
;
; Order matters: when captures overlap, the later pattern wins. Bodies come
; first so the heads, values and any nested tags below paint over them.

; body paragraphs take the colour of their tag
(block_tag body: (body (paragraph) @fey.tag.block.body))
(pair_tag body: (body (paragraph) @fey.tag.pair.body))
(line_tag (body) @fey.tag.line.body)

; name + head open/close bracket and token, one colour per tag format
(scope_tag [ (tag_start) (tag_name) (tag_end) ] @fey.tag.scope)
(block_tag [ (tag_start) (tag_name) (tag_end) ] @fey.tag.block)
(line_tag [ (tag_start) (tag_name) (tag_end) (body_end) ] @fey.tag.line)
(pair_open [ (tag_start) (tag_name) (tag_end) ] @fey.tag.pair)
(pair_close [ (tag_start) (tag_name) (tag_end) ] @fey.tag.pair)

; head contents: values (including the value of a key-value), then keys and
; delimiters on top
(value) @fey.tag.value
(key) @fey.tag.key
"tag_delimiter" @fey.tag.delimiter

; tables
(table (row "|" @fey.table.delimiter))
(table (row_block (row "|" @fey.table.delimiter)))
(cell [ "empty" "|" ] @fey.table.delimiter)
(table . (row (cell (contents) @fey.table.heading)))
(table (hr) @fey.table.delimiter)
(table (row_block (hr) @fey.table.delimiter))
(table (row_block (cbo) @fey.table.delimiter))
(table (row_block (cbe) @fey.table.delimiter))
; how to check for the non-existence of (contents) in cbi_cell to not color that (vmerge)
(table (row_block (cbi "+" @fey.table.delimiter (cbi_cell [ "div" (cb_corner) (vmerge) ] @fey.table.delimiter))))

; (table (cbi "+" @fey.table.delimiter (cbi_cell [ "|" "div" "empty" "term" ] @fey.table.delimiter)))
; (table (cbi (cbi_cell (contents) @FeyParagraph)))
