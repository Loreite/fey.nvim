#!/bin/bash
# Run everything that checks the plugin, and say what failed:
#
#   scripts/test.sh                 every headless suite, the docs parse, the screen checks, the grammar corpus
#   scripts/test.sh --fast          the headless suites and the docs only (what the pre-commit hook runs)
#   scripts/test.sh agenda export   only the suites with these names (tests/agenda.lua, tests/export.lua)
#
# The tree-sitter parser: set FEY_PARSER to the built `fey.so`, or have it installed where Neovim finds it.
# The grammar corpus runs when the `tree-sitter` command and FEY_GRAMMAR (the directory of tree-sitter-fey) are there.
# The screen checks run when `tmux` is there and FEY_PARSER is set.
cd "$(dirname "$0")/.." || exit 1

fast=0
names=()
for arg in "$@"; do
  case "$arg" in
    --fast) fast=1 ;;
    -h | --help) sed -n '2,12p' "$0"; exit 0 ;;
    *) names+=("$arg") ;;
  esac
done

NVIM_BIN=${NVIM_BIN:-nvim}
results=()
failed=0
total=0

run() { # label, command...
  local label="$1"; shift
  local start=$SECONDS out code
  out=$("$@" 2>&1)
  code=$?
  total=$((total + 1))
  if [ $code -ne 0 ]; then
    failed=$((failed + 1))
    results+=("FAIL  $label ($((SECONDS - start))s)")
    printf '%s\n' "$out" | grep -v '^\s*$' | tail -25 | sed "s/^/      /"
  else
    results+=("ok    $label ($((SECONDS - start))s)")
  fi
}

# no parser, no test: say so once instead of failing every suite
if ! "$NVIM_BIN" --headless --clean -c "lua local ok, res = pcall(vim.treesitter.language.add, 'fey', vim.env.FEY_PARSER and { path = vim.env.FEY_PARSER } or nil); vim.cmd((ok and res) and 'qa!' or 'cquit 1')" >/dev/null 2>&1; then
  echo "The fey tree-sitter parser is not there: set FEY_PARSER to the built fey.so (tree-sitter build in tree-sitter-fey), or install it where Neovim finds it."
  exit 2
fi

suites=()
if [ ${#names[@]} -gt 0 ]; then
  for n in "${names[@]}"; do suites+=("tests/$n.lua"); done
else
  for f in tests/*.lua; do
    case "$f" in tests/screen_init.lua) continue ;; esac
    suites+=("$f")
  done
fi

for f in "${suites[@]}"; do
  [ -f "$f" ] || { echo "no such suite: $f"; failed=$((failed + 1)); continue; }
  run "$(basename "$f" .lua)" "$NVIM_BIN" --headless --clean -l "$f"
done

if [ ${#names[@]} -eq 0 ]; then
  if [ -n "$FEY_PARSER" ]; then
    run "docs: README and TASKS parse" "$NVIM_BIN" --headless --clean -c "lua vim.treesitter.language.add('fey',{path=vim.env.FEY_PARSER}); local bad={}; for _,f in ipairs({'TASKS.fey','TASKS_COMPLETED.fey','README.fey'}) do local t=table.concat(vim.fn.readfile(f),'\\n'); if vim.treesitter.get_string_parser(t,'fey'):parse()[1]:root():has_error() then bad[#bad+1]=f end end; if #bad>0 then print('parse errors: '..table.concat(bad,', ')); vim.cmd('cquit 1') end" -c q
  fi
  if [ $fast -eq 0 ]; then
    if command -v tmux >/dev/null && [ -n "$FEY_PARSER" ]; then
      run "screen" bash tests/screen.sh
    else
      results+=("skip  screen (needs tmux and FEY_PARSER)")
    fi
    if command -v tree-sitter >/dev/null && [ -n "$FEY_GRAMMAR" ] && [ -d "$FEY_GRAMMAR" ]; then
      run "grammar corpus" bash -c 'cd "$0" && tree-sitter test' "$FEY_GRAMMAR"
    else
      results+=("skip  grammar corpus (needs tree-sitter and FEY_GRAMMAR)")
    fi
  fi
fi

echo
printf '%s\n' "${results[@]}"
echo
if [ $failed -gt 0 ]; then echo "$failed of $total failed"; exit 1; fi
echo "all $total passed"
