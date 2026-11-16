import std/[os, unittest, strutils]

import carne/gen/docs

proc writePkg(dir: string) =
  createDir(dir)
  writeFile(dir / "package.json",
    "{\n  \"name\": \"greet\",\n  \"version\": \"1.2.0\",\n" &
    "  \"description\": \"Say hi\",\n  \"license\": \"MIT\",\n" &
    "  \"main\": \"index.js\"\n}\n")

test "parseJsdoc reads description, params, returns and examples":
  let info = parseJsdoc(
    "\n * Say hello.\n * @param {string} [name] - who to greet\n" &
    " * @returns {string} the greeting\n * @example\n * hello(\"ada\")\n ")
  check info.description == "Say hello."
  check info.params.len == 1
  check info.params[0].name == "name"
  check info.params[0].typ == "string"
  check info.params[0].optional
  check info.params[0].description == "who to greet"
  check info.returnsType == "string"
  check info.returns == "the greeting"
  check info.examples == @["hello(\"ada\")"]
  check not info.deprecated

test "parseJsdoc splits inline tags on one line":
  let info = parseJsdoc(
    " Farewell. @param {string} name - who leaves @returns {string} bye ")
  check info.description == "Farewell."
  check info.params.len == 1
  check info.params[0].name == "name"
  check info.returnsType == "string"

test "parseJsdoc marks deprecated":
  let info = parseJsdoc(" Old. @deprecated use hello instead ")
  check info.deprecated
  check info.deprecatedMsg == "use hello instead"

test "parseFormat accepts json, html, all and empty":
  check parseFormat("") == dfAll
  check parseFormat("all") == dfAll
  check parseFormat("json") == dfJson
  check parseFormat("HTML") == dfHtml
  expect DocsError:
    discard parseFormat("bogus")

test "highlightJs never throws and escapes on input":
  check highlightJs("hello(name)").contains("<span")
  check highlightJs("").len >= 0

test "docsCommand documents CJS exports only":
  let dir = getTempDir() / "carne_gendocs_cjs"
  if dirExists(dir):
    removeDir(dir)
  writePkg(dir)
  writeFile(dir / "index.js",
    "/**\n * Say hello.\n * @param {string} [name] - who to greet\n" &
    " * @returns {string} the greeting\n */\n" &
    "function hello(name = \"world\") {\n  return \"Hello, \" + name;\n}\n" &
    "/** Farewell. */\nconst bye = (name) => \"Bye, \" + name;\n" &
    "const internal = 1;\nmodule.exports = { hello, bye };\n")
  defer: removeDir(dir)
  check docsCommand(dir, "json", dir / "carnedocs", "") == 0
  check fileExists(dir / "carnedocs" / "docgen.json")
  check not fileExists(dir / "carnedocs" / "index.html")
  let raw = readFile(dir / "carnedocs" / "docgen.json")
  check raw.contains("\"hello\"")
  check raw.contains("hello(name = ")
  check raw.contains("world")
  check raw.contains("\"bye\"")
  check raw.contains("bye(name)")
  check not raw.contains("internal")
  check raw.contains("<span")

test "docsCommand documents ESM and skips tests":
  let dir = getTempDir() / "carne_gendocs_esm"
  if dirExists(dir):
    removeDir(dir)
  writePkg(dir)
  createDir(dir / "lib")
  createDir(dir / "tests")
  writeFile(dir / "index.js",
    "/** Adds. @param {number} a - first @returns {number} sum */\n" &
    "export function add(a, b) { return a + b; }\n" &
    "/** A counter. */\nexport class Counter {}\n" &
    "/** Hidden. */\nexport function _h() {}\n" &
    "export default add;\n")
  writeFile(dir / "lib" / "util.js",
    "/** Doubles. */\nexport function twice(x) { return x * 2; }\n")
  writeFile(dir / "tests" / "x.test.js",
    "export function nope() {}\n")
  defer: removeDir(dir)
  check docsCommand(dir, "all", dir / "carnedocs", "") == 0
  check fileExists(dir / "carnedocs" / "docgen.json")
  check fileExists(dir / "carnedocs" / "index.html")
  check fileExists(dir / "carnedocs" / "assets" / "style.css")
  let raw = readFile(dir / "carnedocs" / "docgen.json")
  check raw.contains("\"add\"")
  check raw.contains("add(a, b)")
  check raw.contains("\"Counter\"")
  check raw.contains("default(a, b)")
  check raw.contains("\"private\": true")
  check not raw.contains("nope")
  let html = readFile(dir / "carnedocs" / "index.html")
  check html.contains("<span")
  check not html.contains("<script")

test "docsCommand honors entry and format":
  let dir = getTempDir() / "carne_gendocs_entry"
  if dirExists(dir):
    removeDir(dir)
  writePkg(dir)
  createDir(dir / "lib")
  writeFile(dir / "index.js", "module.exports = { a: 1 };\n")
  writeFile(dir / "lib" / "util.js",
    "/** Doubles. */\nexport function twice(x) { return x * 2; }\n")
  defer: removeDir(dir)
  check docsCommand(dir, "html", dir / "out", "lib" / "util.js") == 0
  check fileExists(dir / "out" / "index.html")
  check not fileExists(dir / "out" / "docgen.json")
  check readFile(dir / "out" / "index.html").contains("twice")

test "docsCommand errors without a package":
  let dir = getTempDir() / "carne_gendocs_nopkg"
  if dirExists(dir):
    removeDir(dir)
  createDir(dir)
  defer: removeDir(dir)
  check docsCommand(dir, "all", dir / "carnedocs", "") == 1
