([
 (section)
 (table)
;  (drawer)
;  (property_drawer)
 (block)
 ] @fold (#fey-set-fold-offset! @fold))

; block tags fold their body, pair tags fold the lines between the opener and the closer
([
 (block_tag)
 (pair_tag)
 ] @fold (#fey-fold-tag-body! @fold))
