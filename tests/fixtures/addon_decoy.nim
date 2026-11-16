# A shared library that is NOT a carne addon (no entry points).
proc decoy*() {.exportc, cdecl, dynlib.} =
  discard
