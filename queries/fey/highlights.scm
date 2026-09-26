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
(row "|" @fey.table.delimiter)
(cell [ "empty" "|" ] @fey.table.delimiter)
(table . (row (cell (contents) @fey.table.heading)))
(table (hr) @fey.table.delimiter)
(table (cbo) @fey.table.delimiter)
(table (cbe) @fey.table.delimiter)
(table (cbi "+" @fey.table.delimiter (cbi_cell [ "+" "div" "empty" ] @fey.table.delimiter)))
; (table (cbi "+" @fey.table.delimiter (cbi_cell [ "|" "div" "empty" "term" ] @fey.table.delimiter)))
; (table (cbi (cbi_cell (contents) @FeyParagraph)))

