# Carne `carne build` — compile a native addon.
#
#   carne build <input.nim> <output>
#
# Drives `nim c --app:lib --threads:on -d:carneAddon` over an addon
# source written against `carne/api/addon`. Carne sources resolve as
# CARNE_SRC (a checkout) first, then clue's develop checkout
# (`~/.clue/develop/carne`, the normal setup on clue machines), then
# a nimble-installed `carne` package, otherwise the build fails
# closed telling the user to install carne as a Nimble library.
# Transitive dependency `--path` entries come from the nearest
# clue.lock (the addon project's own, else carne's own); with a
# nimble-resolved carne, nimble's own resolution covers them.
# An extensionless output gains the canonical `.addon` extension.
#
# This module stays threads-free and importable from unit tests.

import std/[os, osproc, strutils]

import pkg/openparser/json

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

proc clueDevelopDir*(): string =
  ## The clue develop checkout directory for `carne`, "" when absent.
  ## `~/.clue/develop/carne` is a symlink at the checkout root (or a
  ## real directory); CLUE_HOME overrides the home when set.
  let home = getEnv("CLUE_HOME", getHomeDir() / ".clue").strip()
  if home.len == 0:
    return ""
  let link = home / "develop" / "carne"
  try:
    let dir = expandFilename(link)
    if dirExists(dir / "src" / "carne" / "api"):
      return dir
  except OSError:
    discard
  ""

proc nimbleCarneDir*(): string =
  ## A nimble-installed `carne` package root, "" when absent.
  try:
    let (outp, code) = execCmdEx("nimble path carne")
    if code == 0:
      let root = outp.strip()
      if dirExists(root / "src" / "carne" / "api"):
        return root
  except CatchableError:
    discard
  ""

proc resolveCarneSrc*(envSrc, clueDir, nimbleDir: string): string =
  ## Pure resolution step (seams injected for tests): first hit wins.
  ## Returns the `src` directory holding `carne/api/addon.nim`, or "".
  for c in [envSrc, clueDir, nimbleDir]:
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
  resolveCarneSrc(envSrc, clueDevelopDir(), nimbleCarneDir())

proc findLockUpwards*(start: string): string =
  ## Nearest `clue.lock` walking up from `start`, "" when none.
  var dir =
    if isAbsolute(start): start
    else: getCurrentDir() / start
  if not dirExists(dir):
    dir = parentDir(dir)
  var depth = 0
  while depth < 20:
    let cand = dir / "clue.lock"
    if fileExists(cand):
      return cand
    let parent = parentDir(dir)
    if parent == dir:
      return ""
    dir = parent
    inc depth
  ""

proc lockDepPaths*(lockFile: string): seq[string] =
  ## Every resolved package path in a clue.lock, @[] when unreadable.
  try:
    let lock = parseJson(readFile(lockFile))
    for p in lock["packages"]:
      let path = p["path"].getStr()
      if path.len > 0 and path notin result:
        result.add(path)
  except CatchableError:
    discard

proc depPathsFor*(srcFile, carneSrc: string): seq[string] =
  ## `--path` entries for an addon compile: the carne sources plus
  ## the transitive deps from the nearest clue.lock (the addon
  ## project's own, else carne's own checkout lock).
  result = @[]
  if carneSrc.len > 0:
    result.add(carneSrc)
  var lock = findLockUpwards(absolutePath(srcFile).parentDir())
  if lock.len == 0 and carneSrc.len > 0:
    let own = carneSrc / ".." / "clue.lock"
    if fileExists(own):
      lock = own
  if lock.len > 0:
    for p in lockDepPaths(lock):
      if p notin result:
        result.add(p)

proc buildCommand*(inFile, outFile: string): int =
  ## `carne build` entry point. Returns the process exit code.
  let src = inFile.strip()
  var dest = outFile.strip()
  if src.len == 0 or dest.len == 0:
    displayError("usage: carne build <input.nim> <output>")
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
  let csrc = carneSrcDir()
  if csrc.len == 0:
    displayError("cannot find the carne library: install carne as a " &
      "Nim package via nimble or clue (or point CARNE_SRC at a checkout)")
    return 1
  var cmd = "nim c --app:lib --threads:on -d:carneAddon --hints:off"
  for p in depPathsFor(src, csrc):
    cmd.add(" --path:" & quoteShell(p))
  cmd.add(" -o:" & quoteShell(dest))
  cmd.add(" " & quoteShell(src))
  let code = execShellCmd(cmd)
  if code != 0:
    displayError("build failed for " & src)
    return 1
  displaySuccess("built " & dest)
  0
