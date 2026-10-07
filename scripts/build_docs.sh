#!/bin/bash
# Build the documentation: the generated parts of docs/*.fey, then the help file doc/fey.txt and its tags.
#
#   scripts/build_docs.sh
#
# The pages are Fey files. The exporter of the plugin writes them as one Markdown document, pandoc reads that and `panvimdoc.lua` writes the help file.
# Needs `pandoc` and FEY_PARSER (the built fey.so) or the grammar installed where Neovim finds it.
set -e
SCRIPTPATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
ROOT="$SCRIPTPATH/.."
NVIM_BIN=${NVIM_BIN:-nvim}

# the order of the pages in the help file
PAGES=(index installation tutorial configuration tags mappings plugins troubleshoot contributing changelog)

cd "$ROOT"
"$NVIM_BIN" --headless --clean -l scripts/gen_docs.lua

FILES=()
for page in "${PAGES[@]}"; do FILES+=("docs/$page.fey"); done
TMP=$(mktemp -d)
"$NVIM_BIN" --headless --clean -l scripts/export_md.lua "${FILES[@]}" > "$TMP/fey.md"

cd "$SCRIPTPATH"
pandoc \
  --shift-heading-level-by=0 \
  --metadata=project:fey \
  --metadata=vimversion:Neovim \
  --metadata=toc:true \
  '--metadata=description:A plugin for notes in the Fey markup language' \
  '--metadata=titledatepattern:%Y %B %d' \
  --metadata=dedupsubheadings:true \
  --metadata=ignorerawblocks:true \
  --metadata=docmapping:true \
  --metadata=docmappingproject:true \
  --metadata=treesitter:true \
  --metadata=incrementheadinglevelby:0 \
  -f gfm+tex_math_dollars \
  -t "$SCRIPTPATH/panvimdoc.lua" \
  "$TMP/fey.md" \
  -o "$ROOT/doc/fey.txt"
rm -rf "$TMP"

# the tags of the help files
"$NVIM_BIN" --headless --clean -c "helptags $ROOT/doc" -c q
echo "doc/fey.txt and doc/tags written"
