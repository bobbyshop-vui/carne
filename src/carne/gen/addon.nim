# Carne `carne gen addon` — scaffold a native addon project.
#
#   carne gen addon <dir>
#
# Generates a Node-addon-style package: a JS wrapper (`index.js`,
# loadable via `require("pkg/<name>")`) around a Nim shared library
# (`native/<name>.nim`, built with `nim c --app:lib`). The wrapper
# picks the prebuilt binary per platform; `native/build.sh` compiles
# it (needs CARNE_SRC pointing at a carne checkout).
#
# This module stays threads-free and importable from unit tests.

import std/[os, strutils]

import ../cli
import ../pkg/pkgmanifest

type
  AddonError* = object of CatchableError
    ## A `carne gen addon` usage or scaffold error (message is user-facing).

proc addonNameOk(dir, name: string) =
  ## Raises AddonError when `name` fails the package name rules.
  try:
    validateName(dir / "package.json", name)
  except PackageManifestError as e:
    raise newException(AddonError, e.msg)

proc nativeTemplate(name: string): string =
  ## Starter addon source: one string function, one numeric function.
  result = "import carne/api/addon\n"
  result.add("\n")
  result.add("newAddon(\"" & name & "\", \"0.1.0\"):\n")
  result.add("  exportObject:\n")
  result.add("    registerFn hello(name: default(string, \"world\")):\n")
  result.add("      ## hello([name]) -> greeting string\n")
  result.add("      return toJS(ctx, \"Hello, \" & name & \"!\")\n")
  result.add("    registerFn add(a: int, b: int):\n")
  result.add("      ## add(a, b) -> number\n")
  result.add("      return toJS(ctx, a + b)\n")

proc indexTemplate(name: string): string =
  ## JS wrapper: scalar type checking lives at the native boundary
  ## (wrong types throw TypeError from Nim), so the wrapper only
  ## handles JS-side concerns: adapting shapes and composing behavior.
  result = "// " & name & " — JS wrapper around the native addon.\n"
  result.add("// Build it first: ./native/build.sh.\n")
  result.add("const native = require(\"./native/" & name & ".addon\");\n")
  result.add("\n")
  result.add("const { hello, add } = native;\n")
  result.add("\n")
  result.add("function greetAll(names) {\n")
  result.add("  if (!Array.isArray(names)) {\n")
  result.add("    throw new TypeError(\"greetAll: names must be an array\");\n")
  result.add("  }\n")
  result.add("  return names.map((name) => hello(name));\n")
  result.add("}\n")
  result.add("\n")
  result.add("function shout(name) {\n")
  result.add("  return hello(name).toUpperCase() + \"!\";\n")
  result.add("}\n")
  result.add("\n")
  result.add("module.exports = { hello, add, greetAll, shout };\n")

proc manifestTemplate(name: string): string =
  result = "{\n"
  result.add("  \"name\": \"" & name & "\",\n")
  result.add("  \"version\": \"0.1.0\",\n")
  result.add("  \"description\": \"Native addon for carne\",\n")
  result.add("  \"license\": \"MIT\",\n")
  result.add("  \"main\": \"index.js\",\n")
  result.add("  \"keywords\": [\"carne\"]\n")
  result.add("}\n")

proc nimbleTemplate(name: string): string =
  ## Declares the build dependency: creating Nim-based addons
  ## requires carne as a Nimble library.
  result = "# Package\n"
  result.add("\n")
  result.add("version       = \"0.1.0\"\n")
  result.add("author        = \"\"\n")
  result.add("description   = \"Native addon for carne\"\n")
  result.add("license       = \"MIT\"\n")
  result.add("\n")
  result.add("\n")
  result.add("# Dependencies\n")
  result.add("\n")
  result.add("requires \"nim >= 2.2.0\"\n")
  result.add("requires \"carne >= " & versionStr & "\"\n")

proc buildScriptTemplate(name: string): string =
  result = "#!/bin/sh\n"
  result.add("# Builds the native addon (carne resolves as a Nim package\n")
  result.add("# via nimble or clue; CARNE_SRC overrides with a checkout).\n")
  result.add("set -e\n")
  result.add("HERE=\"$(dirname \"$0\")\"\n")
  result.add("carne build \"$HERE/" & name & ".nim\" \"$HERE/" & name & ".addon\"\n")

proc readmeTemplate(name: string): string =
  result = "# " & name & "\n"
  result.add("\n")
  result.add("Native addon for [carne](https://github.com/getcarne/carne):\n")
  result.add("Nim shared library (`native/" & name & ".nim`) with a JS\n")
  result.add("wrapper (`index.js`) that loads the prebuilt `native/" &
    name & ".addon` binary.\n")
  result.add("\n")
  result.add("Building requires carne as a Nim package, via nimble or\n")
  result.add("clue.\n")
  result.add("\n")
  result.add("## Build\n")
  result.add("\n")
  result.add("```sh\n")
  result.add("./native/build.sh\n")
  result.add("```\n")
  result.add("\n")
  result.add("## Use\n")
  result.add("\n")
  result.add("```js\n")
  result.add("const addon = require(\"./index.js\");\n")
  result.add("console.log(addon.hello(\"ada\")); // Hello, ada!\n")
  result.add("console.log(addon.add(2, 3));      // 5\n")
  result.add("console.log(addon.greetAll([\"ada\", \"grace\"]));\n")
  result.add("console.log(addon.shout(\"ada\")); // HELLO, ADA!!\n")
  result.add("```\n")

proc addonCommand*(target: string): int =
  ## `carne gen addon` entry point. Returns the process exit code.
  let dir = target.strip()
  if dir.len == 0:
    displayError("usage: carne gen addon <dir>")
    return 1
  let name = splitPath(absolutePath(dir)).tail.toLowerAscii()
  try:
    addonNameOk(dir, name)
  except AddonError as e:
    displayError(e.msg)
    return 1
  if dirExists(dir):
    for _ in walkDir(dir):
      displayError("directory is not empty: " & dir)
      return 1
  else:
    try:
      createDir(dir / "native")
    except OSError as e:
      displayError("cannot create " & dir & ": " & e.msg)
      return 1
  try:
    writeFile(dir / "native" / name & ".nim", nativeTemplate(name))
    writeFile(dir / name & ".nimble", nimbleTemplate(name))
    writeFile(dir / "index.js", indexTemplate(name))
    writeFile(dir / "package.json", manifestTemplate(name))
    writeFile(dir / "native" / "build.sh", buildScriptTemplate(name))
    writeFile(dir / "README.md", readmeTemplate(name))
  except OSError as e:
    displayError("cannot write scaffold: " & e.msg)
    return 1
  displaySuccess("addon " & name & " in " & dir & "/ (build: ./native/build.sh)")
  0
