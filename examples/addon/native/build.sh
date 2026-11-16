#!/bin/sh
# Builds the native addon (carne resolves as a Nim package via nimble
# or clue; CARNE_SRC overrides with a checkout).
set -e
HERE="$(dirname "$0")"
carne build "$HERE/hello.nim" "$HERE/hello.addon"
