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

rm -rf "$TMP"
if [ "$failed" -gt 0 ]; then echo "screen: $failed of $total checks failed"; exit 1; fi
echo "ok: $total screen checks"
