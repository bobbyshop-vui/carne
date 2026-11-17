#!/bin/sh
# cliapp: run the terminal example like a real CLI, without the
# `carne run <script>` noise: `./cliapp.sh greet --name ada -v`.
# Script args ($@) pass through verbatim; carne's own flags (such as
# --isatty) must come before `run`, so set CARNE_FLAGS for those
# (example: CARNE_FLAGS=--isatty:true ./cliapp.sh info).
# CARNE selects the binary (default: carne on PATH).
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
: "${CARNE:=carne}"
: "${CARNE_FLAGS:=}"
# shellcheck disable=SC2086
exec "$CARNE" $CARNE_FLAGS run "$here/terminal.js" "$@"
