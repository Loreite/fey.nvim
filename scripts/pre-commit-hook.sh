#!/bin/bash
# Pre-commit hook: the Lua files that are staged must be formatted, and the fast tests must pass.
# Install it with `scripts/install_hooks.sh`. It never formats files for you (that would also change what you did not stage);
# it tells you which files to run `stylua` on.
cd "$(git rev-parse --show-toplevel)" || exit 1

staged=$(git diff --cached --name-only --diff-filter=ACMR -- '*.lua')
if [ -n "$staged" ] && command -v stylua >/dev/null; then
  bad=$(echo "$staged" | xargs stylua --check 2>&1 | grep -c '^Diff in')
  if [ "$bad" -gt 0 ]; then
    echo "pre-commit: these files are not formatted, run: stylua $(echo "$staged" | tr '\n' ' ')"
    exit 1
  fi
fi

if [ -n "$staged" ] || git diff --cached --name-only | grep -q -e '\.fey$' -e '^queries/'; then
  scripts/test.sh --fast || { echo "pre-commit: the tests fail, the commit is not made (git commit --no-verify skips this)"; exit 1; }
fi
exit 0
