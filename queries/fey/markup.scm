; Emphasis markers. One capture per marker character; emphasis.lua pairs the
; captures into spans and treats two adjacent markers as a double (`!!x!!`).
; Capture names are `emphasis.<name>` (see `markers` in emphasis.lua).

; fg + text style            single: fg + style   double: bg, fg + style
(expr "_" @emphasis.underline)
(expr "!" @emphasis.bold)
(expr "/" @emphasis.italic)
(expr "~" @emphasis.strikethrough)

; colours                    single: coloured fg  double: highlight band
(expr "$" @emphasis.red)
(expr "^" @emphasis.orange)
(expr "*" @emphasis.green)
(expr "&" @emphasis.yellow)
(expr "%" @emphasis.fuscia)
(expr "#" @emphasis.blue)
(expr "=" @emphasis.purple)
(expr "-" @emphasis.teal)
(expr "+" @emphasis.dim)

; verbatim (literal; any of four delimiters)
(expr "?" @emphasis.verbatim)
(expr "," @emphasis.verbatim)
(expr ";" @emphasis.verbatim)

; plain verbatim (literal, no highlight of its own: takes the outer one)
(expr "." @emphasis.plain)
(expr ":" @emphasis.plain)

; code (literal)
(expr "`" @emphasis.code)

; quotes (literal)
(expr "'" @emphasis.quote)
(expr "\"" @emphasis.quote)
