;; Level-based heading highlighting using a custom predicate matcher
(heading (signature) @signature (#fey-is-heading-level? @signature "1")) @fey.heading.level1
(heading (signature) @signature (#fey-is-heading-level? @signature "2")) @fey.heading.level2
(heading (signature) @signature (#fey-is-heading-level? @signature "3")) @fey.heading.level3
(heading (signature) @signature (#fey-is-heading-level? @signature "4")) @fey.heading.level4
(heading (signature) @signature (#fey-is-heading-level? @signature "5")) @fey.heading.level5
(heading (signature) @signature (#fey-is-heading-level? @signature "6")) @fey.heading.level6
(heading (signature) @signature (#fey-is-heading-level? @signature "7")) @fey.heading.level7
(heading (signature) @signature (#fey-is-heading-level? @signature "8")) @fey.heading.level8
(body (paragraph) @spell)
(list (listitem (paragraph) @spell))
(bullet) @fey.bullet

;
(block [ (fence) (expr) ] @fey.block)

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

