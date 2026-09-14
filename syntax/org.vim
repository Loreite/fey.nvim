if exists('b:current_syntax')
  finish
endif

let s:highlight_latex = luaeval('require("fey.config").fey_highlight_latex_and_related')

if s:highlight_latex == 'native'
  unlet! b:current_syntax
  runtime! syntax/tex.vim
elseif s:highlight_latex == 'entities'
  syntax include @feyLatex syntax/tex.vim
  unlet! b:current_syntax
  syntax region fey_latex matchgroup=NONE start="^\s*\\begin{.*}$" end="^\s*\\end{.*}$" keepend contains=@feyLatex
  syntax region fey_latex matchgroup=NONE start="^\s*\\begin{.*}$" end="^\s*\\end{.*}$" keepend contains=@feyLatex
  syntax region fey_latex matchgroup=NONE start="\S\zs\$\|\$\S\@="  end="\S\zs\$\|\$\S\@="  keepend oneline contains=@feyLatex
  syntax region fey_latex matchgroup=NONE start="\$\$\|\$\$\@="  end="\$\$\|\$\$\@="  keepend oneline contains=@feyLatex
  syntax region fey_latex matchgroup=NONE start="\\)\|\\(\@="  end="\\)\|\\(\@="  keepend oneline contains=@feyLatex
  syntax region fey_latex matchgroup=NONE start="\\\]\|\\\[\@="  end="\\\]\|\\\[\@="  keepend oneline contains=@feyLatex
endif

let b:current_syntax = 'fey'

" vi: ft=vim:tw=80:sw=4:ts=4:fdm=marker
