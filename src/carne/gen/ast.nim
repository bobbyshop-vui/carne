# Carne `carne gen ast` — JavaScript AST dumps to JSON or binary .ast.
#
#   carne gen ast <file.js> [--format:json|bin] [--out:dir]
#
# Parses one JavaScript file with sweetsyntax and writes its AST beside
# the input (or into --out): `<base>.json` (minified, via openparser's
# generic serializer — the same shape sweetsyntax's own `ast` command
# prints) or `<base>.ast` (binary, via the custom FBE codec below).
# One output per run; `--format` picks which (default: json).
#
# The .ast codec is FBE-framed: magic "CAST" + an FBE root struct
# (version 1; field 1 = source path, field 2 = top-level nodes as a
# vector of inner node structs). Each node is an inner struct:
# field 1 = kind byte, 2 = line, 3 = column, 4..10 = leaf payload by
# kind (bool/int/float/string/bigint/imaginary/ident), 11 = children
# vector. Unknown field ids are skipped so newer writers stay readable;
# magic and version are checked strictly.
#
# This module stays threads-free and importable from unit tests.

import std/[os, strutils]

import pkg/openparser/json
import pkg/openparser/fbe

import sweetsyntax
import sweetsyntax/languages/js

import ../cli

type
  AstError* = object of CatchableError
    ## A `carne gen ast` usage or codec error (message is user-facing).

  AstFormat* = enum
    ## Output selection for `carne gen ast` (one or the other, never both).
    afJson
    afBin

const astParseFeatures = {featAsync, featArrowFn, featGenerators,
  featLabeledStmt, featTemplateLit}
  ## sweetsyntax features for JavaScript (same set as `gen docs`).

const
  astMagic = "CAST"
    ## File magic heading every .ast blob.
  astCodecVersion = 1'u32
    ## Codec version in the FBE root header. Bump on any wire change.

proc parseAstFormat*(s: string): AstFormat =
  ## `json` | `bin` ("" means json). Raises AstError otherwise.
  case s.strip().toLowerAscii()
  of "", "json":
    afJson
  of "bin":
    afBin
  else:
    raise newException(AstError,
      "unknown format \"" & s.strip() & "\" (want json or bin)")

proc programToJson*(prog: OpenAstProgram): string =
  ## Minified JSON of a parsed program (one line + trailing newline).
  toJson(prog) & "\n"

proc sameTree*(a, b: Node): bool =
  ## Structural equality of two ASTs (kind, payload, position, children).
  if a.isNil or b.isNil:
    return a.isNil and b.isNil
  if a.kind != b.kind or a.ln != b.ln or a.col != b.col:
    return false
  case a.kind
  of nkLitBool:
    a.valBool == b.valBool
  of nkLitInt:
    a.valInt == b.valInt
  of nkLitFloat:
    a.valFloat == b.valFloat
  of nkLitString:
    a.valStr == b.valStr
  of nkLitBigInt:
    a.valBigInt == b.valBigInt
  of nkImaginary:
    a.valImag == b.valImag
  of nkIdent:
    a.name == b.name
  of nkEmpty, nkNil:
    true
  else:
    if a.children.len != b.children.len:
      return false
    for i in 0 ..< a.children.len:
      if not sameTree(a.children[i], b.children[i]):
        return false
    true

proc sameProgram*(a, b: OpenAstProgram): bool =
  ## Structural equality of two programs.
  if a.isNil or b.isNil:
    return a.isNil and b.isNil
  if a.nodes.len != b.nodes.len:
    return false
  for i in 0 ..< a.nodes.len:
    if not sameTree(a.nodes[i], b.nodes[i]):
      return false
  true

proc encodeNode(b: var Buffer; n: Node) =
  ## One node as an FBE inner struct (see module header for fields).
  b.beginInnerStruct(astCodecVersion)
  b.encodeHook(1, uint8(ord(n.kind)))
  b.encodeHook(2, int32(n.ln))
  b.encodeHook(3, int32(n.col))
  case n.kind
  of nkLitBool:
    b.encodeHook(4, n.valBool)
  of nkLitInt:
    b.encodeHook(5, int64(n.valInt))
  of nkLitFloat:
    b.encodeHook(6, n.valFloat)
  of nkLitString:
    b.encodeHook(7, n.valStr)
  of nkLitBigInt:
    b.encodeHook(8, n.valBigInt)
  of nkImaginary:
    b.encodeHook(9, n.valImag)
  of nkIdent:
    b.encodeHook(10, n.name)
  of nkEmpty, nkNil:
    discard
  else:
    if n.children.len > 0:
      encodeHookVector[Node](b, 11, n.children, encodeNode)
  b.endInnerStruct()

proc decodeNode(b: var Buffer): Node =
  ## Inverse of encodeNode; unknown fields are skipped.
  discard b.beginReadInnerStruct()
  var kindByte = 0'u8
  var ln = 0'i32
  var col = 0'i32
  var bval = false
  var ival = 0'i64
  var fval = 0.0'f64
  var sval = ""
  var kids: seq[Node] = @[]
  while true:
    var fid: uint16
    var fsz: int
    if not b.readFieldHeader(fid, fsz):
      break
    case fid
    of 1:
      kindByte = b.readFieldValue(fsz,
        proc(bb: var Buffer): uint8 = bb.readEnum8u())
    of 2:
      ln = b.readFieldValue(fsz,
        proc(bb: var Buffer): int32 = bb.readInt32LE())
    of 3:
      col = b.readFieldValue(fsz,
        proc(bb: var Buffer): int32 = bb.readInt32LE())
    of 4:
      bval = b.readFieldValue(fsz,
        proc(bb: var Buffer): bool = bb.readBool())
    of 5:
      ival = b.readFieldValue(fsz,
        proc(bb: var Buffer): int64 = bb.readInt64LE())
    of 6:
      fval = b.readFieldValue(fsz,
        proc(bb: var Buffer): float64 = bb.readFloat64LE())
    of 7, 8, 9, 10:
      sval = b.readFieldValue(fsz,
        proc(bb: var Buffer): string = bb.readString())
    of 11:
      kids = b.readFieldValue(fsz,
        proc(bb: var Buffer): seq[Node] =
          readVector[Node](bb,
            proc(bbb: var Buffer): Node = decodeNode(bbb)))
    else:
      b.skipBytes(fsz)
  b.endReadInnerStruct()
  if int(kindByte) > ord(high(NodeKind)):
    raise newException(AstError,
      "corrupt .ast: unknown node kind " & $kindByte)
  let k = NodeKind(kindByte)
  case k
  of nkLitBool:
    Node(kind: k, ln: int(ln), col: int(col), valBool: bval)
  of nkLitInt:
    Node(kind: k, ln: int(ln), col: int(col), valInt: int(ival))
  of nkLitFloat:
    Node(kind: k, ln: int(ln), col: int(col), valFloat: fval)
  of nkLitString:
    Node(kind: k, ln: int(ln), col: int(col), valStr: sval)
  of nkLitBigInt:
    Node(kind: k, ln: int(ln), col: int(col), valBigInt: sval)
  of nkImaginary:
    Node(kind: k, ln: int(ln), col: int(col), valImag: sval)
  of nkIdent:
    Node(kind: k, ln: int(ln), col: int(col), name: sval)
  of nkEmpty, nkNil:
    Node(kind: k, ln: int(ln), col: int(col))
  else:
    Node(kind: k, ln: int(ln), col: int(col), children: kids)

proc encodeProgram*(prog: OpenAstProgram; source = ""): Buffer =
  ## A parsed program as FBE bytes (magic + root struct).
  result = initBuffer()
  result.appendRaw(astMagic.toOpenArrayByte(0, astMagic.high))
  result.beginRootStruct(astCodecVersion)
  result.encodeHook(1, source)
  encodeHookVector[Node](result, 2, prog.nodes, encodeNode)
  result.endRootStruct()

proc decodeProgram*(data: openArray[uint8]): tuple[prog: OpenAstProgram,
    source: string] =
  ## Inverse of encodeProgram. Raises AstError on bad magic, version or
  ## node kinds; FBE raises CatchableError on truncation.
  var b = initBuffer()
  b.appendRaw(data)
  if b.len < astMagic.len:
    raise newException(AstError, "not a carne .ast file (too short)")
  var magic = ""
  for _ in 0 ..< astMagic.len:
    magic.add(char(b.readByte()))
  if magic != astMagic:
    raise newException(AstError, "not a carne .ast file (bad magic)")
  let version = b.beginReadRootStruct()
  if version != astCodecVersion:
    raise newException(AstError, "unsupported .ast version " & $version &
      " (want " & $astCodecVersion & ")")
  var source = ""
  var nodes: seq[Node] = @[]
  while true:
    var fid: uint16
    var fsz: int
    if not b.readFieldHeader(fid, fsz):
      break
    case fid
    of 1:
      source = b.readFieldValue(fsz,
        proc(bb: var Buffer): string = bb.readString())
    of 2:
      nodes = b.readFieldValue(fsz,
        proc(bb: var Buffer): seq[Node] =
          readVector[Node](bb,
            proc(bbb: var Buffer): Node = decodeNode(bbb)))
    else:
      b.skipBytes(fsz)
  b.endReadRootStruct()
  (OpenAstProgram(nodes: nodes), source)

proc bufferToString*(b: Buffer): string =
  ## Raw FBE bytes as a string for writeFile.
  result = newString(b.data.len)
  if result.len > 0:
    copyMem(addr result[0], unsafeAddr b.data[0], result.len)

proc astCommand*(srcPath, formatStr, outDir: string): int =
  ## `carne gen ast` entry point. Returns the process exit code.
  var format = afJson
  try:
    format = parseAstFormat(formatStr)
  except AstError as e:
    displayError(e.msg)
    return 1
  let src = srcPath.strip()
  if src.len == 0:
    displayError(
      "usage: carne gen ast <file> [--format:json|bin] [--out:dir]")
    return 1
  let absSrc =
    if isAbsolute(src): src else: getCurrentDir() / src
  if not fileExists(absSrc):
    displayError("file not found: " & src)
    return 1
  let ext = absSrc.splitFile.ext.strip(chars = {'.'}).toLowerAscii()
  if ext notin ["js", "mjs", "cjs", "jsx"]:
    displayError("unsupported extension ." & ext &
      " (want .js/.mjs/.cjs/.jsx)")
    return 1
  var prog: OpenAstProgram
  try:
    prog = parseScript(absSrc, jsHandlers, astParseFeatures)
  except OpenAstParsingError as e:
    displayError("could not parse " & src & ": " & e.msg)
    return 1
  except CatchableError as e:
    displayError("could not parse " & src & ": " & e.msg)
    return 1
  if prog == nil:
    displayError("could not parse " & src)
    return 1
  let targetDir =
    if outDir.strip().len == 0: parentDir(absSrc)
    else:
      (if isAbsolute(outDir.strip()): outDir.strip()
      else: getCurrentDir() / outDir.strip())
  try:
    createDir(targetDir)
  except OSError, IOError:
    displayError("cannot create " & targetDir & ": " &
      getCurrentExceptionMsg())
    return 1
  let base = splitFile(absSrc).name
  if format == afJson:
    try:
      writeFile(targetDir / (base & ".json"), programToJson(prog))
    except OSError, IOError:
      displayError("cannot write " & base & ".json: " &
        getCurrentExceptionMsg())
      return 1
    displaySuccess("wrote AST of " & extractFilename(absSrc) & " (" &
      $prog.nodes.len &
      " top-level node" & (if prog.nodes.len == 1: "" else: "s") &
      "): " & base & ".json in " & targetDir)
  else:
    try:
      writeFile(targetDir / (base & ".ast"),
        bufferToString(encodeProgram(prog, absSrc)))
    except OSError, IOError:
      displayError("cannot write " & base & ".ast: " &
        getCurrentExceptionMsg())
      return 1
    displaySuccess("wrote AST of " & extractFilename(absSrc) & " (" &
      $prog.nodes.len &
      " top-level node" & (if prog.nodes.len == 1: "" else: "s") &
      "): " & base & ".ast in " & targetDir)
  0
