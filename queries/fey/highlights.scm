;; Level-based headline highlighting using a custom predicate matcher
(heading (signature) @signature (#fey-is-heading-level? @signature "1")) @org.headline.level1
(heading (signature) @signature (#fey-is-heading-level? @signature "2")) @org.headline.level2
(heading (signature) @signature (#fey-is-heading-level? @signature "3")) @org.headline.level3
(heading (signature) @signature (#fey-is-heading-level? @signature "4")) @org.headline.level4
(heading (signature) @signature (#fey-is-heading-level? @signature "5")) @org.headline.level5
(heading (signature) @signature (#fey-is-heading-level? @signature "6")) @org.headline.level6
(heading (signature) @signature (#fey-is-heading-level? @signature "7")) @org.headline.level7
(heading (signature) @signature (#fey-is-heading-level? @signature "8")) @org.headline.level8
(body (paragraph) @spell)
(list (listitem (paragraph) @spell))
(bullet) @org.bullet

