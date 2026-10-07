#!/bin/bash
# Put the pre-commit hook in this clone: it runs `scripts/test.sh --fast` and checks the formatting of the staged Lua files.
cd "$(git rev-parse --show-toplevel)" || exit 1
mkdir -p .git/hooks
ln -sf ../../scripts/pre-commit-hook.sh .git/hooks/pre-commit
chmod +x scripts/pre-commit-hook.sh
echo "installed .git/hooks/pre-commit"
