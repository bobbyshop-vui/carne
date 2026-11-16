# Carne `carne build` — compile a native addon.
#
#   carne build [--release] <input.nim> <output>
#
# Drives `clue build --app:lib --threads:on -d:carneAddon` when clue
# is available (it resolves the package graph itself, including the
# current package and develop checkouts), else raw
# `nim c --app:lib --threads:on -d:carneAddon` with carne sources from
# CARNE_SRC or a nimble-installed `carne` (nimble then covers the
# transitive deps). `--release` adds `-d:release` (optimized). An
# extensionless output gains the canonical `.addon` extension.
#
# This module stays threads-free and importable from unit tests.

import std/[os, osproc, strutils]

import ../cli

when defined(macosx):
  const platformAddonExt* = ".dylib"
    ## Native library extension produced by the platform linker.
else:
  const platformAddonExt* = ".so"
    ## Native library extension produced by the platform linker.

const defaultAddonExt* = ".addon"
  ## Canonical addon output: platform-independent name, so one JS
  ## wrapper loads it everywhere with no platform switch.

proc nimbleCarneDir*(): string =
  ## A nimble-installed `carne` package root, "" when absent. Used
  ## only by the raw-`nim c` fallback (no clue on PATH).
  try:
    let (outp, code) = execCmdEx("nimble path carne")
    if code == 0:
      let root = outp.strip()
      if dirExists(root / "src" / "carne" / "api"):
        return root
  except CatchableError:
    discard
  ""

proc resolveCarneSrc*(envSrc, nimbleDir: string): string =
  ## Pure resolution step (seam injected for tests): first hit wins.
  ## Returns the `src` directory holding `carne/api/addon.nim`, or "".
  for c in [envSrc, nimbleDir]:
    if c.len > 0 and fileExists(c / "src" / "carne" / "api" / "addon.nim"):
      return c / "src"
    if c.len > 0 and fileExists(c / "carne" / "api" / "addon.nim"):
      # Already a `src`-level directory.
      return c
  ""

proc carneSrcDir*(): string =
  ## Directory to pass as `--path` for `import carne/api/addon`,
  ## "" when carne is not resolvable as a library.
  let env = getEnv("CARNE_SRC").strip()
  let envSrc =
    if env.len > 0 and dirExists(env): env
    else: ""
  resolveCarneSrc(envSrc, nimbleCarneDir())

proc buildCommand*(inFile, outFile: string; release = false): int =
  ## `carne build` entry point. Returns the process exit code.
  let src = inFile.strip()
  var dest = outFile.strip()
  if src.len == 0 or dest.len == 0:
    displayError("usage: carne build [--release] <input.nim> <output>")
    return 1
  if not fileExists(src):
    displayError("file not found: " & src)
    return 1
  if splitFile(src).ext != ".nim":
    displayError("input must be a .nim file: " & src)
    return 1
  if splitFile(dest).ext == "":
    dest = changeFileExt(dest, defaultAddonExt)
  try:
    createDir(parentDir(absolutePath(dest)))
  except OSError as e:
    displayError("cannot create output directory: " & e.msg)
    return 1
  let rel = if release: " -d:release" else: ""
  if findExe("clue") != "":
    let code = execShellCmd("clue build --app:lib --threads:on" & rel &
      " -d:carneAddon " & quoteShell(src) & " -o:" & quoteShell(dest))
    if code != 0:
      displayError("build failed for " & src)
      return 1
    displaySuccess("built " & dest)
    return 0
  let csrc = carneSrcDir()
  if csrc.len == 0:
    displayError("cannot find the carne library: install carne as a " &
      "Nim package via nimble or clue (or point CARNE_SRC at a checkout)")
    return 1
  let code = execShellCmd("nim c --app:lib --threads:on" & rel &
    " -d:carneAddon --hints:off --path:" & quoteShell(csrc) &
    " -o:" & quoteShell(dest) & " " & quoteShell(src))
  if code != 0:
    displayError("build failed for " & src)
    return 1
  displaySuccess("built " & dest)
  0
