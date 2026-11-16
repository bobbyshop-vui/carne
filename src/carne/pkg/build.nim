# Carne `carne build` — compile a native addon.
#
#   carne build [--release] <input.nim> <output>
#
# Drives `clue build --app:lib --threads:on -d:carneAddon` when clue
# is available, else raw `nim c` with the same flags. `--release`
# adds `-d:release` (optimized). Either way the full dependency
# closure rides on explicit `--path`s, computed from the nearest
# .nimble walking up from the input: its `requires` (transitively)
# resolved against the local installs (clue develop checkouts, the
# clue package store, nimble pkgs2). This works on any machine with
# or without a lock file, and never depends on which subset a
# manager happens to have indexed. An extensionless output gains the
# canonical `.addon` extension.
#
# This module stays threads-free and importable from unit tests.

import std/[os, osproc, strutils]

import pkg/semver

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
  ## A nimble-installed `carne` package root, "" when absent. Covers
  ## the no-checkout case (addon projects depending on a published
  ## carne).
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

proc checkoutSrcDir*(start: string): string =
  ## Nearest ancestor directory holding `src/carne/api/addon.nim`
  ## (a carne checkout containing `start`), "" when none. Covers
  ## building from inside the carne repo itself.
  var dir = absolutePath(start)
  if not dirExists(dir):
    dir = parentDir(dir)
  var depth = 0
  while depth < 20:
    if dir.len > 0 and
        fileExists(dir / "src" / "carne" / "api" / "addon.nim"):
      return dir / "src"
    let parent = parentDir(dir)
    if parent.len == 0 or parent == dir:
      return ""
    dir = parent
    inc depth
  ""

proc rootNimbleDir*(start: string): string =
  ## Nearest ancestor directory holding a .nimble file, "" when none.
  ## The addon's own project when building from one, else "".
  var dir = absolutePath(start)
  if not dirExists(dir):
    dir = parentDir(dir)
  var depth = 0
  while depth < 20:
    if dir.len > 0:
      try:
        for kind, path in walkDir(dir):
          if kind == pcFile and path.endsWith(".nimble"):
            return dir
      except OSError:
        discard
    let parent = parentDir(dir)
    if parent.len == 0 or parent == dir:
      return ""
    dir = parent
    inc depth
  ""

proc nimbleRequires*(nimbleFile: string): seq[string] =
  ## Dependency names from a .nimble file's `requires` lines
  ## (`requires "name ..."`; comma forms included, `nim` skipped).
  try:
    for line in readFile(nimbleFile).splitLines():
      let t = line.strip()
      if not t.startsWith("requires"):
        continue
      var i = t.find('"')
      while i >= 0:
        let j = t.find('"', i + 1)
        if j < 0:
          break
        let spec = t[i + 1 ..< j].strip()
        var name = spec
        for sep in [' ', '@', '#', '<', '>', '=', '!']:
          let k = name.find(sep)
          if k >= 0:
            name = name[0 ..< k]
            break
        name = name.strip().toLowerAscii()
        if name.len > 0 and name != "nim" and name notin result:
          result.add(name)
        i = t.find('"', j + 1)
  except CatchableError:
    discard

proc bestVerDir*(parent, name: string): string =
  ## Best version subdirectory of `parent/<name>` (max semver wins,
  ## plain names sort lexically), "" when none. Mirrors clue's pick
  ## without depending on its install index.
  let base = parent / name
  if not dirExists(base):
    return ""
  var best = ""
  var bestSemver = false
  var bestVer = ""
  try:
    for kind, path in walkDir(base):
      if kind != pcDir:
        continue
      let d = path.extractFilename()
      var isSemver = false
      var ver = ""
      try:
        discard parseVersion(d)
        isSemver = true
        ver = d
      except CatchableError:
        discard
      if best.len == 0:
        best = d
        bestSemver = isSemver
        bestVer = ver
      elif isSemver and not bestSemver:
        best = d
        bestSemver = true
        bestVer = ver
      elif isSemver == bestSemver:
        if isSemver:
          try:
            if parseVersion(d) > parseVersion(bestVer):
              best = d
              bestVer = ver
          except CatchableError:
            discard
        elif d > best:
          best = d
  except OSError:
    discard
  if best.len > 0:
    base / best
  else:
    ""

proc verLess*(a, b: string): bool =
  ## Semver-aware version order (lexical fallback for non-semver).
  try:
    parseVersion(a) < parseVersion(b)
  except CatchableError:
    a < b

proc pkgVersionKey(dirName, pkgName: string): tuple[ok: bool, ver: string] =
  ## Splits a `<name>-<version>-<hash>` install dir into its version
  ## part ("" when the shape does not match).
  let rest =
    if dirName.toLowerAscii().startsWith(pkgName.toLowerAscii() & "-"):
      dirName[pkgName.len + 1 .. ^1]
    else:
      ""
  let dash = rest.find('-')
  if rest.len == 0 or dash < 0:
    return (false, "")
  try:
    discard parseVersion(rest[0 ..< dash])
    (true, rest[0 ..< dash])
  except CatchableError:
    (false, "")

proc resolvePkgDirs*(home, name: string): seq[string] =
  ## `--path`-able directories providing Nimble package `name`:
  ## the clue develop checkout, the best clue-store version, and the
  ## best nimble pkgs2 copy. Both the package root and a `src`
  ## subdir (when present) are listed; nim searches each.
  if home.len == 0 or name.len == 0:
    return
  var vers: seq[string] = @[]
  let dev = home / ".clue" / "develop" / name
  if dirExists(dev):
    vers.add(dev)
  let storeBest = bestVerDir(home / ".clue" / "packages", name)
  if storeBest.len > 0:
    vers.add(storeBest)
  try:
    var best = ""
    var bestVer = ""
    for kind, path in walkDir(home / ".nimble" / "pkgs2"):
      if kind != pcDir:
        continue
      let (ok, ver) = pkgVersionKey(path.extractFilename(), name)
      if not ok:
        continue
      if best.len == 0 or verLess(bestVer, ver):
        best = path
        bestVer = ver
    if best.len > 0:
      vers.add(best)
  except OSError:
    discard
  for c in vers:
    if c notin result:
      result.add(c)
    if dirExists(c / "src") and (c / "src") notin result:
      result.add(c / "src")

proc closurePaths*(srcFile: string; home = getHomeDir()): seq[string] =
  ## Explicit `--path` entries for compiling `srcFile`: carne itself
  ## plus the transitive `requires` closure of the nearest .nimble
  ## project, each resolved against the local installs. Works with or
  ## without a lock file, on any machine.
  # Carne first (its own checkout when building from it).
  let co = checkoutSrcDir(srcFile)
  if co.len > 0:
    result.add(co)
  else:
    let cs = carneSrcDir()
    if cs.len > 0 and cs notin result:
      result.add(cs)
  # Nearest project manifest, else nothing further to resolve.
  let root = rootNimbleDir(srcFile)
  if root.len == 0:
    return
  var nimbleFile = ""
  try:
    for kind, path in walkDir(root):
      if kind == pcFile and path.endsWith(".nimble"):
        nimbleFile = path
        break
  except OSError:
    discard
  if nimbleFile.len == 0:
    return
  # BFS over requires (guarded: package graphs are DAGs, cap anyway).
  var seen = @["nim"]
  var queue = nimbleRequires(nimbleFile)
  var guard = 0
  while queue.len > 0 and guard < 500:
    inc guard
    let name = queue[0]
    queue.del(0)
    if name in seen:
      continue
    seen.add(name)
    var pkgNimble = ""
    for d in resolvePkgDirs(home, name):
      if d notin result:
        result.add(d)
      if pkgNimble.len == 0:
        for cand in [d / name.changeFileExt("nimble"),
            d / ".." / name.changeFileExt("nimble")]:
          if fileExists(cand):
            pkgNimble = cand
            break
    if pkgNimble.len > 0:
      for dep in nimbleRequires(pkgNimble):
        if dep notin seen:
          queue.add(dep)

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
  var flags = " --app:lib --threads:on" & rel & " -d:carneAddon"
  let paths = closurePaths(src)
  for p in paths:
    flags.add(" --path:" & quoteShell(p))
  if findExe("clue") != "":
    let code = execShellCmd("clue build" & flags &
      " " & quoteShell(src) & " -o:" & quoteShell(dest))
    if code != 0:
      displayError("build failed for " & src)
      return 1
    displaySuccess("built " & dest)
    return 0
  if paths.len == 0:
    displayError("cannot find the carne library: install carne as a " &
      "Nim package via nimble or clue (or point CARNE_SRC at a checkout)")
    return 1
  let code = execShellCmd("nim c" & flags &
    " -o:" & quoteShell(dest) & " " & quoteShell(src))
  if code != 0:
    displayError("build failed for " & src)
    return 1
  displaySuccess("built " & dest)
  0
