syn match @fey.agenda.day /^\S\+\s\+\d\+\s\S\+\s\d\d\d\d$/
syn match @fey.agenda.tag /:[^ ]*:$/

hi default link @fey.agenda.day Statement
hi default link @fey.agenda.today @fey.bold
hi default link @fey.agenda.weekend @fey.bold
hi default link @fey.agenda.weekend.today @fey.bold
hi default link @fey.agenda.header Comment
hi default link @fey.agenda.separator Comment
hi default @fey.agenda.tag gui=bold cterm=bold
