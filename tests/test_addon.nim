import std/[json, os, sequtils, strutils, times, unittest]

import carne
import carne/modules
import carne/pkg/loader
import carne/pkg/pkgman
import carne/gen/addon as genaddon
import carne/pkg/build as addonbuild

const addonExt = ".addon"
  ## Canonical addon extension under test (platform files and
  ## `.node` still load; the `.node` probe has its own case below).

proc repoRoot(): string =
  currentSourcePath.parentDir.parentDir

proc ensureCarneSrc() =
  ## Fixture compiles resolve the checkout through CARNE_SRC.
  putEnv("CARNE_SRC", repoRoot())

proc buildFixture(name: string): string =
  ## Shared build directory across tests in this file (one compile per
  ## fixture per run, not per test), via the real `carne build` path.
  ## Skips the rebuild when the output is newer than the fixture and
  ## the boundary sources (a bridge change must rebuild the addons).
  ensureCarneSrc()
  let dir = getTempDir() / "carne_addon_test"
  createDir(dir)
  result = dir / name & addonExt
  let src = repoRoot() / "tests" / "fixtures" / name & ".nim"
  var newest = getLastModificationTime(src)
  for dep in ["src/carne/bridge.nim", "src/carne/api/addon.nim"]:
    let t = getLastModificationTime(repoRoot() / dep)
    if t > newest:
      newest = t
  if fileExists(result) and getLastModificationTime(result) >= newest:
    return
  check addonbuild.buildCommand(src, result) == 0

proc freshHome(): string =
  result = getTempDir() / "carne_addon_pkg_test"
  if dirExists(result):
    removeDir(result)
  createDir(result)

proc installWrappedAddon(home, lib: string): DatpkgrConfig =
  ## A package whose JS entry wraps the prebuilt native binary, in the
  ## Node addon-package shape: `require("pkg/<name>")` loads JS, the
  ## JS wrapper requires the bundled binary relatively.
  result = newCarnePkgConfig(rootPath = home)
  let checkout = home / "checkout-hello"
  createDir(checkout / "native")
  writeFile(checkout / "package.json",
    """{"name": "hello", "version": "0.1.0", "main": "index.js"}""")
  writeFile(checkout / "index.js",
    "const candidates = [\"./native/hello" & addonExt & "\"];\n" &
    "let native = null;\n" &
    "for (const c of candidates) {\n" &
    "  try { native = require(c); break; } catch (e) {}\n" &
    "}\n" &
    "module.exports = native;\n")
  copyFile(lib, checkout / "native" / "hello" & addonExt)
  check result.developPackage(checkout)
  initPkgLoader(result)

test "addon loads through a package wrapper":
  let home = freshHome()
  defer: removeDir(home)
  discard installWrappedAddon(home, buildFixture("addon_hello"))
  check runCode("require('pkg/hello').hello('ada')") == "Hello, ada!"
  check runCode("require('pkg/hello').hello()") == "Hello, world!"
  check runCode("require('pkg/hello').add(20, 22)") == "42"

test "addon instances are cached per runtime":
  let home = freshHome()
  defer: removeDir(home)
  discard installWrappedAddon(home, buildFixture("addon_hello"))
  check runCode("require('pkg/hello') === require('pkg/hello')") == "true"

test "addon loads through a script-relative require":
  let dir = getTempDir() / "carne_addon_rel_test"
  if dirExists(dir):
    removeDir(dir)
  createDir(dir)
  defer: removeDir(dir)
  copyFile(buildFixture("addon_hello"), dir / "hello" & addonExt)
  copyFile(buildFixture("addon_hello"), dir / "probed.node")
  writeFile(dir / "main.js",
    "require('./hello" & addonExt & "').add(1, 2) + " &
    "require('./probed').add(3, 4) + ';' + " &
    "require('./hello" & addonExt & "').hello('rel');\n")
  check runFile(dir / "main.js") == "10;Hello, rel!"

test "native boundary throws TypeError and honors defaults":
  let home = freshHome()
  defer: removeDir(home)
  discard installWrappedAddon(home, buildFixture("addon_hello"))
  check runCode("require('pkg/hello').hello(undefined)") ==
    "Hello, world!"
  check runCode(
    "try { require('pkg/hello').add('x', 2); 'no' } " &
    "catch (e) { e.constructor.name }") == "TypeError"
  check runCode(
    "try { require('pkg/hello').add(1); 'no' } " &
    "catch (e) { e.constructor.name + ':' + e.message.split('\\n')[0] }") ==
    "TypeError:add: expected 2 argument(s), got 1"
  try:
    discard runCode("require('pkg/hello').add('x', 2)")
    fail()
  except CarneError as e:
    check "type mismatch parameter: `a`" in e.msg

test "missing addon file throws":
  let home = freshHome()
  defer: removeDir(home)
  discard installWrappedAddon(home, buildFixture("addon_hello"))
  expect CarneError:
    discard runCode("require('pkg/hello/../native/nope" & addonExt & "')")

test "non-addon library throws":
  let dir = getTempDir() / "carne_addon_decoy_test"
  if dirExists(dir):
    removeDir(dir)
  createDir(dir)
  defer: removeDir(dir)
  ensureCarneSrc()
  check addonbuild.buildCommand(
    repoRoot() / "tests" / "fixtures" / "addon_decoy.nim",
    dir / "decoy" & addonExt) == 0
  writeFile(dir / "main.js", "require('./decoy" & addonExt & "');\n")
  expect CarneError:
    discard runFile(dir / "main.js")

test "addon with wrong carne major throws":
  let dir = getTempDir() / "carne_addon_badver_test"
  if dirExists(dir):
    removeDir(dir)
  createDir(dir)
  defer: removeDir(dir)
  ensureCarneSrc()
  check addonbuild.buildCommand(
    repoRoot() / "tests" / "fixtures" / "addon_badver.nim",
    dir / "badver" & addonExt) == 0
  writeFile(dir / "main.js", "require('./badver" & addonExt & "');\n")
  try:
    discard runFile(dir / "main.js")
    fail()
  except CarneError as e:
    check "major mismatch" in e.msg

test "carne build compiles an addon":
  let dir = getTempDir() / "carne_build_cmd_test"
  if dirExists(dir):
    removeDir(dir)
  createDir(dir)
  defer: removeDir(dir)
  ensureCarneSrc()
  let lib = dir / "built.addon"
  check addonbuild.buildCommand(
    repoRoot() / "tests" / "fixtures" / "addon_hello.nim", lib) == 0
  check fileExists(lib)
  writeFile(dir / "main.js", "require('./built.addon').add(19, 23);\n")
  check runFile(dir / "main.js") == "42"
  # Usage errors fail closed.
  check addonbuild.buildCommand("", lib) == 1
  check addonbuild.buildCommand(repoRoot() / "tests" / "fixtures" /
    "addon_hello.nim", "") == 1

test "carne source resolution order":
  check addonbuild.resolveCarneSrc("", "") == ""
  check addonbuild.resolveCarneSrc("/nonexistent-xyz", "") == ""
  check addonbuild.resolveCarneSrc(repoRoot(), "") ==
    repoRoot() / "src"
  check addonbuild.checkoutSrcDir(
    repoRoot() / "tests" / "fixtures" / "addon_hello.nim") ==
    repoRoot() / "src"
  check addonbuild.checkoutSrcDir(getTempDir()) == ""

test "closure resolves the repo dependency graph":
  let fx = repoRoot() / "tests" / "fixtures" / "addon_hello.nim"
  check addonbuild.rootNimbleDir(fx) == repoRoot()
  let reqs = addonbuild.nimbleRequires(repoRoot() / "carne.nimble")
  check "semver" in reqs
  check "pluginkit" in reqs
  check "javascriptcore" in reqs
  check "nim" notin reqs
  check addonbuild.resolvePkgDirs(getHomeDir(), "semver").len > 0
  check addonbuild.resolvePkgDirs(getHomeDir(), "no-such-pkg-xyz").len == 0
  let paths = addonbuild.closurePaths(fx)
  check paths.anyIt("semver" in it)
  check paths.anyIt("pluginkit" in it)
  check paths.anyIt("javascriptcore" in it)

test "carne build --release passes -d:release":
  let dir = getTempDir() / "carne_build_release_test"
  if dirExists(dir):
    removeDir(dir)
  createDir(dir)
  defer: removeDir(dir)
  ensureCarneSrc()
  let lib = dir / "decoy_rel.addon"
  check addonbuild.buildCommand(
    repoRoot() / "tests" / "fixtures" / "addon_decoy.nim",
    lib, true) == 0
  check fileExists(lib)

test "carne build resolves carne without CARNE_SRC":
  delEnv("CARNE_SRC")
  defer: ensureCarneSrc()
  if addonbuild.carneSrcDir().len == 0:
    echo "skip: no resolvable carne library on this machine"
  else:
    let dir = getTempDir() / "carne_build_nocenv_test"
    if dirExists(dir):
      removeDir(dir)
    createDir(dir)
    defer: removeDir(dir)
    let lib = dir / "nocenv.addon"
    check addonbuild.buildCommand(
      repoRoot() / "tests" / "fixtures" / "addon_hello.nim", lib) == 0
    writeFile(dir / "main.js",
      "require('./nocenv.addon').hello('clue');\n")
    check runFile(dir / "main.js") == "Hello, clue!"

test "gen addon scaffolds a project":
  let dir = getTempDir() / "carne_gen_addon_test"
  if dirExists(dir):
    removeDir(dir)
  defer: removeDir(dir)
  check genaddon.addonCommand(dir / "hello") == 0
  check fileExists(dir / "hello" / "package.json")
  check fileExists(dir / "hello" / "hello.nimble")
  check fileExists(dir / "hello" / "index.js")
  check fileExists(dir / "hello" / "native" / "hello.nim")
  check fileExists(dir / "hello" / "native" / "build.sh")
  check fileExists(dir / "hello" / "README.md")
  let manifest = parseJson(readFile(dir / "hello" / "package.json"))
  check manifest["name"].getStr() == "hello"
  check manifest["main"].getStr() == "index.js"
  check "requires \"carne" in readFile(dir / "hello" / "hello.nimble")
  check "newAddon(\"hello\", \"0.1.0\")" in
    readFile(dir / "hello" / "native" / "hello.nim")
  check "require(\"./native/hello.addon\")" in
    readFile(dir / "hello" / "index.js")
  # Scalar checks live at the native boundary: no manual guards.
  check "typeof" notin readFile(dir / "hello" / "index.js")
  # Refuses a non-empty target.
  check genaddon.addonCommand(dir / "hello") == 1
