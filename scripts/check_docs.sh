#!/bin/bash
# The documentation checks: the generated list of mappings in README.fey is current, the README and the
# roadmap parse, every mapping has a description, and the API reference is complete.
#
#   FEY_PARSER=/path/to/fey.so scripts/check_docs.sh [path/to/tutorial/vault]
set -e
cd "$(dirname "$0")/.."
nvim --headless -u NONE -l scripts/gen_mappings.lua --check
FEY_TUTORIAL="$1" nvim --headless --clean -l tests/docs.lua
