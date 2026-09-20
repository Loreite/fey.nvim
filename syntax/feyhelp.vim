syntax match feyhelp_key /`[^`]*`/ contains=feyhelp_backtick
syntax match feyhelp_bold /^\s*\*\*[^\*]*\*\*$/ contains=feyhelp_asterisk
syntax match feyhelp_title /^\s*__[^_]*__$/ contains=feyhelp_underscore
syntax match feyhelp_backtick /`/ cchar= conceal contained
syntax match feyhelp_asterisk /\*\*/ cchar= conceal contained
syntax match feyhelp_underscore /__/ cchar= conceal contained

hi def feyhelp_bold gui=bold cterm=bold
hi def link feyhelp_title Title
hi def link feyhelp_key Function
