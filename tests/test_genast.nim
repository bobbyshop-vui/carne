import std/[os, unittest, strutils]

import pkg/openparser/json

import sweetsyntax
import sweetsyntax/languages/js

import carne/gen/ast

const jsFeatures = {featAsync, featArrowFn, featGenerators,
  featLabeledStmt, featTemplateLit}

const payloadJs =
  "const t = true;\n" &
  "const n = 42;\n" &
  "const f = 1.5;\n" &
  "const s = \"hi\";\n" &
  "const big = 10n;\n" &
  "const nothing = null;\n" &
  "const re = /ab+c/g;\n" &
  "const msg = `hi ${n}!`;\n" &
  "function add(a, b = 2, ...rest) {\n  return a + b;\n}\n" &
  "const dbl = (x) => x * 2;\n" &
  "add(1, 2);\n"

proc strToBytes(s: string): seq[uint8] =
  result = newSeq[uint8](s.len)
  if s.len > 0:
    copyMem(addr result[0], unsafeAddr s[0], s.len)

proc freshDir(name: string): string =
  result = getTempDir() / name
  if dirExists(result):
    removeDir(result)
  createDir(result)

test "parseAstFormat accepts json, bin and empty":
  check parseAstFormat("") == afJson
  check parseAstFormat("json") == afJson
  check parseAstFormat("BIN") == afBin
  expect AstError:
    discard parseAstFormat("bogus")
  expect AstError:
    discard parseAstFormat("all")

test "programToJson is valid JSON with kinds and names":
  let dir = freshDir("carne_genast_json")
  defer: removeDir(dir)
  writeFile(dir / "a.js", payloadJs)
  let prog = parseScript(dir / "a.js", jsHandlers, jsFeatures)
  let raw = programToJson(prog)
  check raw.endsWith("\n")
  let root = fromJson(raw)
  check root.kind == JObject
  check root["nodes"].kind == JArray
  check root["nodes"].len == prog.nodes.len
  check raw.contains("nkFunction")
  check raw.contains("add")
  check raw.contains("nkLitString")

test "binary codec round-trips every payload kind":
  let dir = freshDir("carne_genast_roundtrip")
  defer: removeDir(dir)
  writeFile(dir / "a.js", payloadJs)
  let prog = parseScript(dir / "a.js", jsHandlers, jsFeatures)
  let buf = encodeProgram(prog, dir / "a.js")
  check buf.data.len > 4
  check char(buf.data[0]) == 'C'
  check char(buf.data[1]) == 'A'
  check char(buf.data[2]) == 'S'
  check char(buf.data[3]) == 'T'
  let (back, source) = decodeProgram(buf.data)
  check source == dir / "a.js"
  check sameProgram(prog, back)

test "binary codec round-trips an empty program":
  let prog = OpenAstProgram(nodes: @[])
  let (back, _) = decodeProgram(encodeProgram(prog).data)
  check sameProgram(prog, back)

test "decodeProgram rejects bad magic, versions and truncation":
  let dir = freshDir("carne_genast_bad")
  defer: removeDir(dir)
  writeFile(dir / "a.js", payloadJs)
  let prog = parseScript(dir / "a.js", jsHandlers, jsFeatures)
  let good = encodeProgram(prog).data
  var badMagic = good
  badMagic[0] = uint8('X')
  expect AstError:
    discard decodeProgram(badMagic)
  expect AstError:
    discard decodeProgram(newSeq[uint8](2))
  var badVersion = good
  # root version lives at bytes 8..11 (after magic + totalSize)
  badVersion[8] = 99'u8
  expect AstError:
    discard decodeProgram(badVersion)
  expect CatchableError:
    discard decodeProgram(good[0 ..< good.len - 3])

test "astCommand writes one output per run, json by default":
  let dir = freshDir("carne_genast_cmd")
  defer: removeDir(dir)
  writeFile(dir / "hello.js",
    "/** Say hello. */\nfunction hello(name = \"world\") {\n" &
    "  return \"Hello, \" + name;\n}\nmodule.exports = { hello };\n")
  check astCommand(dir / "hello.js", "", dir / "out") == 0
  check fileExists(dir / "out" / "hello.json")
  check not fileExists(dir / "out" / "hello.ast")
  let raw = readFile(dir / "out" / "hello.json")
  check raw.contains("hello")
  check raw.contains("nkFunction")
  check astCommand(dir / "hello.js", "bin", dir / "outbin") == 0
  check fileExists(dir / "outbin" / "hello.ast")
  check not fileExists(dir / "outbin" / "hello.json")
  let prog = parseScript(dir / "hello.js", jsHandlers, jsFeatures)
  let (back, _) = decodeProgram(strToBytes(readFile(dir / "outbin" /
      "hello.ast")))
  check sameProgram(prog, back)

test "astCommand honors explicit json and defaults beside input":
  let dir = freshDir("carne_genast_fmt")
  defer: removeDir(dir)
  writeFile(dir / "a.js", "const x = 1;\n")
  check astCommand(dir / "a.js", "json", "") == 0
  check fileExists(dir / "a.json")
  check not fileExists(dir / "a.ast")

test "astCommand errors on missing files, extensions and syntax":
  let dir = freshDir("carne_genast_err")
  defer: removeDir(dir)
  check astCommand(dir / "nope.js", "json", "") == 1
  writeFile(dir / "a.txt", "hello")
  check astCommand(dir / "a.txt", "json", "") == 1
  writeFile(dir / "bad.js", "const = ;\n")
  check astCommand(dir / "bad.js", "bin", "") == 1
  writeFile(dir / "ok.js", "const x = 1;\n")
  check astCommand(dir / "ok.js", "bogus", "") == 1
  check astCommand("", "json", "") == 1
