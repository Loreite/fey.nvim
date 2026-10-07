#!/bin/bash
# What is drawn, not what is in the buffer: opens files in a real Neovim inside tmux and reads the screen.
# Skipped without tmux. Run from the repo root with the parser built:
#
#   FEY_PARSER=/path/to/fey.so tests/screen.sh
cd "$(dirname "$0")/.." || exit 1
command -v tmux >/dev/null || { echo "screen: tmux is not installed, skipped"; exit 0; }
export FEY_ROOT="$PWD"
: "${FEY_PARSER:?set FEY_PARSER to the built parser}"
TMP=$(mktemp -d)
total=0
failed=0

screen_of() { # file, extra keys...
  local file="$1"; shift
  tmux -L fey_screen kill-server 2>/dev/null
  tmux -L fey_screen new-session -d -x 100 -y 40 "nvim -u tests/screen_init.lua $file"
  sleep 2
  for cmd in "$@"; do tmux -L fey_screen send-keys "$cmd" Enter; sleep 0.5; done
  sleep 0.5
  tmux -L fey_screen capture-pane -p
  tmux -L fey_screen kill-server 2>/dev/null
}
check() { # name, haystack, needle (fixed string), want: yes|no
  total=$((total + 1))
  if [ "$4" = yes ]; then
    grep -qF -- "$3" <<<"$2" || { echo "FAIL $1: '$3' is not on the screen"; failed=$((failed + 1)); }
  else
    grep -qF -- "$3" <<<"$2" && { echo "FAIL $1: '$3' is on the screen"; failed=$((failed + 1)); }
  fi
}

cat >"$TMP/boxes.fey" <<'EOF'
  I. Boxes

-  [ ] open
-  [x] done
-  [/] progress
-  [!] important
-  [n] a note
EOF
export FEY_OPTS="{ fey_checkbox_icons = 'unicode' }"
out=$(screen_of "$TMP/boxes.fey" ':normal zR' ':normal G')
check 'a done box is an icon' "$out" '☑ done' yes
check 'an open box is an icon' "$out" '☐ open' yes
check 'an important box' "$out" '‼ important' yes
check 'the box is hidden' "$out" '[x]' no
check 'the line of the cursor shows the box as written' "$out" '[n] a note' yes

export FEY_OPTS="{ fey_show_checkbox_state_as_icons = false }"
out=$(screen_of "$TMP/boxes.fey" ':normal zR' ':normal gg')
check 'switched off, the boxes are as written' "$out" '[x] done' yes

cat >"$TMP/notes.fey" <<'EOF'
  I. Notes

A claim {@ fn, 12 @} and a word {@ fn, note @}.

[ fn, 12 #]
Pair text.
[# fn ]

#[ fn, 12 ] Line text. #

[ fn, 12 ]#
    Block text.
EOF
export FEY_OPTS="{}"
out=$(screen_of "$TMP/notes.fey" ':normal zR' ':normal G')
check 'a reference is superscript' "$out" 'A claim ¹²' yes
check 'a label with letters stays as written in auto' "$out" '{@ fn, note @}' yes
check 'the tag syntax is hidden' "$out" '{@ fn, 12 @}' no
check 'a line definition shows the label before its text' "$out" '¹² Line text.' yes
export FEY_OPTS="{ fey_footnote_superscript = false }"
out=$(screen_of "$TMP/notes.fey" ':normal zR' ':normal G')
check 'superscript off: the tags are as written' "$out" '{@ fn, 12 @}' yes

# settings from the court and the note, applied while the note is open
mkdir -p "$TMP/court/.fey" "$TMP/plain"
cat >"$TMP/court/.fey/config.fey" <<'EOF'
{# nvim; number: true #}
EOF
cat >"$TMP/plain/note.fey" <<'EOF'
  I. A note

Some text.
EOF
cat >"$TMP/plain/own.fey" <<'EOF'
{# nvim; number: false #}
  I. A note with its own setting

Some text.
EOF
export FEY_OPTS="{ fey_court_dir = '$TMP/court' }"
out=$(screen_of "$TMP/plain/note.fey" ':sleep 700m' ':normal zR')
check 'the court sets line numbers for a note without a setting' "$out" '  1   I. A note' yes
out=$(screen_of "$TMP/plain/own.fey" ':sleep 700m' ':normal zR')
check 'the note beats the court' "$out" '  1 ' no


# concealed queries: the tag and its body are hidden, the result keeps its body but not its head and closer
cat >"$TMP/conceal.fey" <<'EOF'
  I. Concealed

before

[ query; conceal: true ]#
   LIST WITHOUT ID file.name
[ query_result; conceal: true #]
-  shown result
[# query_result ]

after {# query, LIST; conceal: true #} the line

between

[ query_result #]
-  plain result
[# query_result ]
EOF
export FEY_OPTS="{ fey_court_dir = '$TMP/court', fey_checkbox_icons = 'unicode' }"
out=$(screen_of "$TMP/conceal.fey" ':set conceallevel=2' ':normal zR' ':normal G')
check 'the body of a result stays' "$out" 'shown result' yes
check 'an icon stands where the query was' "$out" '≣' yes
check 'a concealed query body is hidden' "$out" 'LIST WITHOUT ID' no
check 'a concealed result head is hidden' "$out" 'query_result; conceal' no
total=$((total + 1))
[ "$(grep -cF -- '[# query_result ]' <<<"$out")" = 1 ] || { echo "FAIL only the closer of the plain result is drawn"; failed=$((failed + 1)); }
check 'an inline concealed tag is an icon' "$out" 'after ≣ the line' yes
check 'a result with no conceal shows its head' "$out" '[ query_result #]' yes
# the cursor in the object shows all of it, from the first line of the query to the closer of the result
out=$(screen_of "$TMP/conceal.fey" ':set conceallevel=2' ':normal zR' ':normal 7G')
check 'the cursor in the result shows the query' "$out" 'LIST WITHOUT ID file.name' yes
check 'and the head of the result' "$out" '[ query_result; conceal: true #]' yes
check 'and the closer of the result' "$out" '[# query_result ]' yes
total=$((total + 1))
[ "$(grep -cF -- '≣' <<<"$out")" = 1 ] || { echo "FAIL the object the cursor is in has no icon, the other one has"; failed=$((failed + 1)); }
out=$(screen_of "$TMP/conceal.fey" ':set conceallevel=2' ':normal zR' ':normal 7G' ':normal 3G')
check 'leaving it hides it again' "$out" 'LIST WITHOUT ID' no


# completion inside the head of a tag, through the omnifunc
printf '  I. Pop\n\n' >"$TMP/pop.fey"
unset FEY_OPTS
out=$(screen_of "$TMP/pop.fey" ':normal zR' ':call feedkeys("Go{# status, \<C-x>\<C-o>", "nt")')
check 'the todo keywords are offered in a status tag' "$out" 'TODO [Fey]' yes
check 'and the done ones' "$out" 'DONE [Fey]' yes


# concealed links: a scope tag shows its description, the other forms lose their head, the cursor line shows all
cat >"$TMP/linkc.fey" <<'EOF'
  I. Links

see {@ link, notes/a.fey; desc: The notes; conceal: true @} here

#[ link, b.fey; conceal: true ] linked words #

[ link, c.fey; conceal: true ]#
   a paragraph that is the link

plain {@ link, e.fey; desc: Visible @} link
EOF
export FEY_OPTS="{ fey_court_dir = '$TMP/court' }"
out=$(screen_of "$TMP/linkc.fey" ':set conceallevel=2' ':normal zR' ':normal G')
check 'a scope link shows its description' "$out" 'see The notes here' yes
check 'and not its syntax' "$out" 'notes/a.fey' no
check 'a line link keeps its words' "$out" 'linked words' yes
check 'and loses its head' "$out" 'b.fey' no
check 'a block link keeps its body' "$out" 'a paragraph that is the link' yes
check 'and loses its head line' "$out" '[ link, c.fey' no
check 'a link without the key is as written' "$out" '{@ link, e.fey; desc: Visible @}' yes
out=$(screen_of "$TMP/linkc.fey" ':set conceallevel=2' ':normal zR' ':normal 3G')
check 'on the cursor line the link is as written' "$out" '{@ link, notes/a.fey; desc: The notes; conceal: true @}' yes
check 'other links stay hidden there' "$out" 'b.fey' no


# folding at startup, and the ellipsis of a closed fold
printf '  I. Folded\n\nhidden body\n\n  II. Next\n\nshown\n' >"$TMP/fold.fey"
export FEY_OPTS="{ fey_startup_folded = 'overview', fey_ellipsis = ' [..]' }"
out=$(screen_of "$TMP/fold.fey")
check 'startup folded: the body is hidden' "$out" 'hidden body' no
check 'with the ellipsis of the option' "$out" 'Folded [..]' yes
export FEY_OPTS="{ fey_startup_folded = 'showeverything' }"
out=$(screen_of "$TMP/fold.fey")
check 'not folded at startup: the body is shown' "$out" 'hidden body' yes
unset FEY_OPTS

rm -rf "$TMP"
if [ "$failed" -gt 0 ]; then echo "screen: $failed of $total checks failed"; exit 1; fi
echo "ok: $total screen checks"
