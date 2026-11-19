#!/bin/sh
# Verify highlightlocator.lua against diff-match-patch.
# Needs luajit and Python with the diff-match-patch package (set PYTHON to pick an interpreter).
set -e
here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$here")
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
luajit "$here/gen_patches.lua" "$repo" "$here/sample.html" "$out"
"${PYTHON:-python3}" "$here/check_patches.py" "$out"
