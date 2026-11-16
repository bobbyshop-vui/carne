# Carne `carne gen docs` — API reference from JS sources.
#
#   carne gen docs [--format:json|html|all] [--out:carnedocs] [--entry:file]
#
# Run inside a package directory (a `package.json` must resolve from the
# cwd upward). Parses every public JS file with sweetsyntax, keeps only
# exported symbols (ESM `export ...` plus CommonJS
# `module.exports`/`exports.*`) with their JSDoc, and writes a `carnedocs`
# directory holding `docgen.json` (machine feed for json-based docs) and/or
# static `index.html` + `assets/style.css`.
#
# HTML highlighting is baked in at generation time with sweetsyntax's
# lexer-only renderer (`highlight(KnownSyntax.js, code, hfHtml)` with
# filters off — a filter spec regex crashes the highlighter process on
# object literals, and filters are decoration anyway). The emitted pages
# carry no <script> and need no client-side highlighter.
#
# This module stays threads-free and importable from unit tests.

import std/[os, strutils, tables, algorithm, sequtils]

import pkg/openparser/json

import sweetsyntax
import sweetsyntax/languages/js
import sweetsyntax/renderers/highlight

import ../cli
import ../pkg/pkgmanifest

type
  DocsError* = object of CatchableError
    ## A `carne gen docs` usage or generation error (message is user-facing).

  DocFormat* = enum
    ## Output selection for `carne gen docs`.
    dfJson
    dfHtml
    dfAll

  JsdocParam* = object
    ## One `@param` entry.
    name*: string
    typ*: string
    optional*: bool
    description*: string

  JsdocInfo* = object
    ## Parsed JSDoc block: leading description plus tags.
    description*: string
    params*: seq[JsdocParam]
    returnsType*: string
    returns*: string
    examples*: seq[string]
    deprecated*: bool
    deprecatedMsg*: string

  DocSymbol* = object
    ## One exported symbol in one file.
    name*: string
    kind*: string
    file*: string
    line*: int
    signature*: string
    signatureHtml*: string
    description*: string
    params*: seq[JsdocParam]
    returnsType*: string
    returns*: string
    examples*: seq[string]
    examplesHtml*: seq[string]
    deprecated*: bool
    deprecatedMsg*: string
    isPrivate*: bool

const jsParseFeatures = {featAsync, featArrowFn, featGenerators,
  featLabeledStmt, featTemplateLit}

const skippedDirs = ["node_modules", ".git", "coverage", "dist", "build",
  "tests", "test", "__tests__", "examples", "bench", "vendor"]
  ## Directory names never scanned for API sources.

proc escapeHtml*(s: string): string =
  ## Minimal HTML escaping for prose and code fallbacks.
  s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    .replace("\"", "&quot;")

proc highlightJs*(code: string): string =
  ## sweetsyntax HTML for a JS snippet, filters off (see module header).
  ## Falls back to escaped code on any failure — docs must never die on
  ## highlighting.
  try:
    result = highlight(KnownSyntax.js, code, hfHtml, true, false)
  except CatchableError:
    result = escapeHtml(code)

proc stripDocStars(raw: string): seq[string] =
  ## Raw `/** ... */` text into clean lines: drops the fence markers and
  ## one leading `*` per line.
  for line in raw.splitLines():
    var s = line.strip()
    if s.startsWith("/**"):
      s = s[3 .. ^1].strip()
      if s.endsWith("*/"):
        s = s[0 .. ^3].strip()
      if s.len > 0:
        result.add(s)
      continue
    if s.startsWith("/*"):
      s = s[2 .. ^1].strip()
    if s.endsWith("*/"):
      s = s[0 .. ^3].strip()
    if s.startsWith("*"):
      s = s[1 .. ^1].strip()
    result.add(s)

proc splitTagBody(body: string; tag, rest: var string) =
  ## `@param {string} name - desc` into ("param", "{string} name - desc").
  let b = body.strip()
  var i = 1
  while i < b.len and b[i] notin {' ', '\t', '\n', '\r'}:
    inc i
  tag = b[1 ..< i]
  rest = if i < b.len: b[i .. ^1].strip() else: ""

proc takeBraceType(s: string; typ, rest: var string) =
  ## `{string} tail` into ("string", "tail"); no braces leaves typ empty.
  if s.startsWith("{"):
    let c = s.find('}')
    if c > 0:
      typ = s[1 ..< c].strip()
      rest = s[c + 1 .. ^1].strip()
      return
  typ = ""
  rest = s

proc parseJsdoc*(raw: string): JsdocInfo =
  ## Parses a doc-comment body. Description is everything before the first
  ## `@tag`; `@param`, `@returns`/`@return`, `@example` (kept verbatim,
  ## may repeat) and `@deprecated` are understood, the rest ignored.
  result = JsdocInfo()
  let rawLines = stripDocStars(raw)
  # Single-line blocks (`/** Farewell. @param {string} name - x */`)
  # carry tags mid-line: split them onto their own lines first.
  var lines: seq[string] = @[]
  for ln in rawLines:
    var rest = ln.strip()
    while true:
      let at = rest.find(" @")
      if at < 0 or at + 2 >= rest.len or
          rest[at + 2] notin {'a'..'z', 'A'..'Z'}:
        break
      let head = rest[0 ..< at].strip()
      if head.len > 0:
        lines.add(head)
      rest = rest[at + 1 .. ^1].strip()
    if rest.len > 0 or lines.len == 0:
      lines.add(rest)
  var desc: seq[string] = @[]
  var blocks: seq[string] = @[]
  var cur = ""
  var inTag = false
  for ln in lines:
    if ln.startsWith("@") and ln.len > 1 and
        ln[1] in {'a'..'z', 'A'..'Z'}:
      if inTag:
        blocks.add(cur)
      cur = ln
      inTag = true
    else:
      if inTag:
        cur.add("\n" & ln)
      else:
        desc.add(ln)
  if inTag:
    blocks.add(cur)
  while desc.len > 0 and desc[0].len == 0:
    desc.delete(0)
  while desc.len > 0 and desc[^1].len == 0:
    desc.delete(desc.high)
  result.description = desc.join("\n")
  for b in blocks:
    var tag, rest: string
    splitTagBody(b, tag, rest)
    case tag
    of "param", "arg", "argument":
      var typ, tail: string
      takeBraceType(rest, typ, tail)
      var name = ""
      var about = ""
      let t = tail.strip()
      if t.len > 0:
        let parts = t.splitWhitespace(maxsplit = 1)
        name = parts[0]
        if name.startsWith("-"):
          about = t
          name = ""
        elif parts.len > 1:
          about = parts[1].strip()
          if about.startsWith("-"):
            about = about[1 .. ^1].strip()
      var opt = false
      if name.startsWith("[") and name.endsWith("]"):
        opt = true
        name = name[1 .. ^2]
        let eq = name.find('=')
        if eq >= 0:
          name = name[0 ..< eq]
      if name.len > 0:
        result.params.add(JsdocParam(name: name, typ: typ, optional: opt,
          description: about))
    of "returns", "return":
      var typ, tail: string
      takeBraceType(rest, typ, tail)
      result.returnsType = typ
      result.returns = tail.strip()
    of "example":
      let code = rest.strip(chars = {'\n', '\r'})
      if code.len > 0:
        result.examples.add(code)
    of "deprecated":
      result.deprecated = true
      result.deprecatedMsg = rest.strip()
    else:
      discard

proc opName(n: Node): string =
  ## Operator name of an nkInfix node ("" otherwise).
  if n != nil and n.kind == nkInfix and n.children.len > 0 and
      n.children[0].kind == nkIdent:
    n.children[0].name
  else:
    ""

proc isDotOf(n: Node; a, b: string): bool =
  ## True for `a.b` dot expressions.
  n != nil and n.kind == nkDotExpr and n.children.len == 2 and
    n.children[0].kind == nkIdent and n.children[0].name == a and
    n.children[1].kind == nkIdent and n.children[1].name == b

proc isModuleExports(n: Node): bool =
  ## True for `module.exports` (possibly nested as `module.exports.x`).
  isDotOf(n, "module", "exports") or
    (n != nil and n.kind == nkDotExpr and n.children.len == 2 and
      isModuleExports(n.children[0]) and n.children[1].kind == nkIdent)

proc reprValue(n: Node): string =
  ## Short source-ish rendering of a default/export value.
  if n == nil or n.kind == nkEmpty:
    return ""
  case n.kind
  of nkLitString:
    if n.valStr.len >= 2 and n.valStr[0] == '"' and
        n.valStr[^1] == '"':
      n.valStr
    else:
      "\"" & n.valStr & "\""
  of nkLitInt:
    $n.valInt
  of nkLitFloat:
    $n.valFloat
  of nkLitBool:
    $n.valBool
  of nkIdent:
    n.name
  of nkArrayLit:
    "[...]"
  of nkBlock:
    "{...}"
  else:
    "..."

proc paramText(p: Node): string =
  ## One parameter rendering: `name`, `name = default`, `...rest`.
  if p == nil:
    return ""
  case p.kind
  of nkIdent:
    p.name
  of nkPrefix:
    if p.children.len == 2 and p.children[0].kind == nkIdent and
        p.children[0].name == "..." and p.children[1].kind == nkIdent:
      "..." & p.children[1].name
    else:
      "..."
  of nkIdentDefs:
    if p.children.len == 0:
      return ""
    if p.children[0].kind != nkIdent:
      return "{...}"
    let nm = p.children[0].name
    var dflt = ""
    if p.children.len >= 3:
      dflt = reprValue(p.children[2])
    elif p.children.len == 2:
      dflt = reprValue(p.children[1])
    if dflt.len > 0:
      nm & " = " & dflt
    else:
      nm
  else:
    "{...}"

proc paramsOf(fn: Node): seq[string] =
  ## Parameter list of a function node across its shape variants.
  if fn == nil or fn.kind != nkFunction:
    return @[]
  let n = fn.children.len
  var box: Node = nil
  if n == 7 and fn.children[4].kind == nkIdentDefs:
    box = fn.children[4]
  elif n == 3 and fn.children[1].kind == nkIdentDefs:
    box = fn.children[1]
  else:
    for c in fn.children:
      if c != nil and c.kind == nkIdentDefs and c.children.len > 0 and
          (c.children[0].kind != nkIdent or
            not c.children[0].name.startsWith("[")):
        box = c
        break
  if box == nil:
    return @[]
  for p in box.children:
    if p == nil or p.kind == nkEmpty:
      continue
    if p.kind == nkIdentDefs and p.children.len > 0 and
        p.children[0].kind == nkIdent and p.children[0].name.len == 0:
      continue
    result.add(paramText(p))

proc fnNameOf(fn: Node): string =
  ## Declared name of a function node ("" when anonymous).
  if fn == nil or fn.kind != nkFunction:
    return ""
  let n = fn.children.len
  if n == 7 and fn.children[2].kind == nkIdent:
    return fn.children[2].name
  ""

proc funcSignature(name: string; fn: Node): string =
  ## `name(a, b = 1)` rendering.
  name & "(" & paramsOf(fn).join(", ") & ")"

proc parseFormat*(s: string): DocFormat =
  ## `json` | `html` | `all` ("" means all). Raises DocsError otherwise.
  case s.strip().toLowerAscii()
  of "", "all":
    dfAll
  of "json":
    dfJson
  of "html":
    dfHtml
  else:
    raise newException(DocsError,
      "unknown format \"" & s.strip() & "\" (want json, html or all)")

proc packageIdentity(dir: string): tuple[name, version, descr: string] =
  ## Name/version/description from the nearest package.json upward.
  let mf = findPackageJson(dir)
  if mf.len == 0:
    raise newException(DocsError,
      "no package.json found (run `carne gen docs` inside a package directory)")
  let src =
    try:
      readFile(mf)
    except IOError, OSError:
      raise newException(DocsError,
        "cannot read " & mf & ": " & getCurrentExceptionMsg())
  let root =
    try:
      fromJson(src)
    except CatchableError as e:
      raise newException(DocsError, mf & ": invalid JSON: " & e.msg)
  if root.kind != JObject:
    raise newException(DocsError, mf & ": top level must be an object")
  proc strField(f: string): string =
    if root.hasKey(f) and root[f].kind == JString:
      root[f].getStr()
    else:
      ""
  let name = strField("name")
  if name.len == 0:
    raise newException(DocsError, mf & ": \"name\" is required")
  (name, strField("version"), strField("description"))

proc discoverJsFiles(dir, entry, outDir: string): seq[string] =
  ## Files to document: `--entry` alone, else every .js/.mjs/.cjs below
  ## dir minus tooling, test and output directories.
  if entry.len > 0:
    let abs = if isAbsolute(entry): entry else: dir / entry
    if not fileExists(abs):
      raise newException(DocsError, "entry file not found: " & entry)
    return @[abs]
  let outAbs =
    try:
      expandFilename(if isAbsolute(outDir): outDir else: dir / outDir)
    except OSError:
      (if isAbsolute(outDir): outDir else: dir / outDir)
  for path in walkDirRec(dir, yieldFilter = {pcFile}):
    let ext = path.splitFile.ext.toLowerAscii()
    if ext notin [".js", ".mjs", ".cjs"]:
      continue
    let rel = relativePath(path, dir)
    let parts = rel.split(DirSep)
    var skip = false
    for part in parts[0 .. ^2]:
      if part in skippedDirs:
        skip = true
        break
    if skip:
      continue
    try:
      if expandFilename(path).startsWith(outAbs & $DirSep) or
          expandFilename(path) == outAbs:
        continue
    except OSError:
      discard
    result.add(path)
  result.sort()

type
  DefInfo = object
    kind: string
    node: Node
    doc: string
    line: int

proc collectDefinitions(prog: OpenAstProgram): Table[string, DefInfo] =
  ## Top-level `function`/`class`/variable declarations with JSDoc.
  result = initTable[string, DefInfo]()
  var pending = ""
  for top in prog.nodes:
    if top == nil or top.kind == nkEmpty:
      continue
    if top.kind == nkDocComment:
      if top.children.len > 0:
        pending = top.children[0].valStr
      continue
    if top.kind == nkFunction:
      let nm = fnNameOf(top)
      if nm.len > 0 and nm notin result:
        result[nm] = DefInfo(kind: "function", node: top, doc: pending,
          line: top.ln)
      pending = ""
      continue
    if top.kind == nkStatement and top.children.len > 0 and
        top.children[0].kind == nkIdent:
      let kw = top.children[0].name
      if kw == "class" and top.children.len > 1 and
          top.children[1].kind == nkIdent:
        let nm = top.children[1].name
        if nm notin result:
          result[nm] = DefInfo(kind: "class", node: top, doc: pending,
            line: top.ln)
        pending = ""
        continue
      if kw in ["const", "let", "var"]:
        for idef in top.children[1 .. ^1]:
          if idef == nil or idef.kind != nkIdentDefs or
              idef.children.len == 0 or idef.children[0].kind != nkIdent:
            continue
          let nm = idef.children[0].name
          if nm.len > 0 and nm notin result:
            let init =
              if idef.children.len >= 3: idef.children[2]
              elif idef.children.len == 2: idef.children[1]
              else: nil
            let kd = if init != nil and init.kind == nkFunction: "function"
              else: "variable"
            result[nm] = DefInfo(kind: kd, node: idef, doc: pending,
              line: idef.ln)
        pending = ""
        continue
    pending = ""

proc addSymbol(syms: var seq[DocSymbol]; defs: Table[string, DefInfo];
    name, file, rel: string; fallback: Node; doc: string; line: int) =
  ## Records one export, resolving identifiers through the definitions
  ## table so `module.exports = {hello}` inherits hello's docs.
  var kind = "variable"
  var sig = name
  var info = parseJsdoc(doc)
  let ln = if line > 0: line else: 1
  if fallback != nil and fallback.kind == nkIdent and
      defs.hasKey(fallback.name):
    let d = defs[fallback.name]
    kind = d.kind
    info = parseJsdoc(d.doc)
    var fn: Node = nil
    if d.node.kind == nkFunction:
      fn = d.node
    elif d.node.kind == nkIdentDefs:
      let init =
        if d.node.children.len >= 3: d.node.children[2]
        elif d.node.children.len == 2: d.node.children[1]
        else: nil
      if init != nil and init.kind == nkFunction:
        fn = init
    if fn != nil:
      kind = "function"
      sig = funcSignature(name, fn)
    elif d.kind == "class":
      sig = "class " & name
    elif d.kind != "function":
      let init =
        if d.node.kind == nkIdentDefs:
          if d.node.children.len >= 3: d.node.children[2]
          elif d.node.children.len == 2: d.node.children[1]
          else: nil
        else: nil
      let r = reprValue(init)
      sig = if r.len > 0: name & " = " & r else: name
  elif fallback != nil and fallback.kind == nkFunction:
    kind = "function"
    sig = funcSignature(name, fallback)
  elif fallback != nil and fallback.kind == nkStatement and
      fallback.children.len > 0 and fallback.children[0].kind == nkIdent and
      fallback.children[0].name == "class":
    kind = "class"
    sig = "class " & name
  elif fallback != nil:
    let r = reprValue(fallback)
    if r.len > 0 and r notin ["...", "{...}", "[...]"]:
      sig = name & " = " & r
  syms.add(DocSymbol(name: name, kind: kind, file: rel, line: ln,
    signature: sig, description: info.description, params: info.params,
    returnsType: info.returnsType, returns: info.returns,
    examples: info.examples, deprecated: info.deprecated,
    deprecatedMsg: info.deprecatedMsg,
    isPrivate: name.startsWith("_") or name.startsWith("#")))

proc extractFile(path, rel: string): tuple[syms: seq[DocSymbol],
    warned: string] =
  ## Exported symbols of one file; warned is "" on success.
  var prog: OpenAstProgram
  try:
    prog = parseScript(path, jsHandlers, jsParseFeatures)
  except OpenAstParsingError as e:
    return (@[], "skipping " & rel & ": " & e.msg)
  except CatchableError as e:
    return (@[], "skipping " & rel & ": " & e.msg)
  if prog == nil:
    return (@[], "skipping " & rel & ": could not parse")
  var defs = collectDefinitions(prog)
  var syms: seq[DocSymbol] = @[]
  var pending = ""
  for top in prog.nodes:
    if top == nil or top.kind == nkEmpty:
      continue
    if top.kind == nkDocComment:
      if top.children.len > 0:
        pending = top.children[0].valStr
      continue
    if top.kind == nkStatement and top.children.len > 0 and
        top.children[0].kind == nkIdent and
        top.children[0].name == "export":
      let doc = pending
      pending = ""
      if top.children.len < 2:
        continue
      let body = top.children[1]
      if body.kind == nkIdent and body.name == "default" and
          top.children.len > 2:
        let val = top.children[2]
        var info = parseJsdoc(doc)
        var sig = "default"
        if val.kind == nkFunction:
          sig = "default(" & paramsOf(val).join(", ") & ")"
        elif val.kind == nkIdent and defs.hasKey(val.name):
          let d = defs[val.name]
          if d.node.kind == nkFunction:
            sig = "default(" & paramsOf(d.node).join(", ") & ")"
            info = parseJsdoc(d.doc)
        syms.add(DocSymbol(name: "default", kind: "variable", file: rel,
          line: top.ln, signature: sig, description: info.description,
          params: info.params, returnsType: info.returnsType,
          returns: info.returns, examples: info.examples,
          deprecated: info.deprecated, deprecatedMsg: info.deprecatedMsg,
          isPrivate: false))
      elif body.kind == nkFunction:
        let nm = fnNameOf(body)
        if nm.len > 0:
          var info = parseJsdoc(doc)
          syms.add(DocSymbol(name: nm, kind: "function", file: rel,
            line: top.ln, signature: funcSignature(nm, body),
            description: info.description, params: info.params,
            returnsType: info.returnsType, returns: info.returns,
            examples: info.examples, deprecated: info.deprecated,
            deprecatedMsg: info.deprecatedMsg,
            isPrivate: nm.startsWith("_") or nm.startsWith("#")))
          if nm notin defs:
            defs[nm] = DefInfo(kind: "function", node: body, doc: doc,
              line: top.ln)
      elif body.kind == nkStatement and body.children.len > 0 and
          body.children[0].kind == nkIdent:
        let kw = body.children[0].name
        if kw == "class" and body.children.len > 1 and
            body.children[1].kind == nkIdent:
          let nm = body.children[1].name
          var info = parseJsdoc(doc)
          syms.add(DocSymbol(name: nm, kind: "class", file: rel,
            line: top.ln, signature: "class " & nm,
            description: info.description, params: info.params,
            returnsType: info.returnsType, returns: info.returns,
            examples: info.examples, deprecated: info.deprecated,
            deprecatedMsg: info.deprecatedMsg,
            isPrivate: nm.startsWith("_")))
          if nm notin defs:
            defs[nm] = DefInfo(kind: "class", node: body, doc: doc,
              line: top.ln)
        elif kw in ["const", "let", "var"]:
          for idef in body.children[1 .. ^1]:
            if idef == nil or idef.kind != nkIdentDefs or
                idef.children.len == 0 or
                idef.children[0].kind != nkIdent:
              continue
            let nm = idef.children[0].name
            if nm.len == 0:
              continue
            var info = parseJsdoc(doc)
            let init =
              if idef.children.len >= 3: idef.children[2]
              elif idef.children.len == 2: idef.children[1]
              else: nil
            let sig =
              if init != nil and init.kind == nkFunction:
                funcSignature(nm, init)
              else:
                let r = reprValue(init)
                if r.len > 0: nm & " = " & r else: nm
            let kd = if init != nil and init.kind == nkFunction: "function"
              else: "variable"
            syms.add(DocSymbol(name: nm, kind: kd, file: rel, line: idef.ln,
              signature: sig, description: info.description,
              params: info.params, returnsType: info.returnsType,
              returns: info.returns, examples: info.examples,
              deprecated: info.deprecated,
              deprecatedMsg: info.deprecatedMsg,
              isPrivate: nm.startsWith("_")))
            if nm notin defs:
              defs[nm] = DefInfo(kind: kd, node: idef, doc: doc,
                line: idef.ln)
        elif kw == "default":
          # Unreachable: `export default expr` parses as
          # Statement[export, Ident(default), expr], handled above.
          discard
      elif body.kind == nkIdentDefs:
        for item in body.children:
          if item == nil:
            continue
          if item.kind == nkIdent and item.name.len > 0:
            addSymbol(syms, defs, item.name, path, rel, item, doc, item.ln)
          elif item.kind == nkInfix and opName(item) == "as" and
              item.children.len == 3 and
              item.children[1].kind == nkIdent and
              item.children[2].kind == nkIdent:
            addSymbol(syms, defs, item.children[2].name, path, rel,
              item.children[1], doc, item.ln)
      elif body.kind == nkIdent and body.name == "*":
        displayWarning("re-export `export *` in " & rel &
          " is listed without symbols (v1 does not follow it)")
      continue
    if top.kind == nkInfix and opName(top) in ["=", "=="] and
        top.children.len == 3:
      let lhs = top.children[1]
      let rhs = top.children[2]
      let doc = pending
      pending = ""
      if isDotOf(lhs, "module", "exports") and rhs.kind == nkBlock:
        for item in rhs.children:
          if item == nil or item.kind != nkColonExpr or
              item.children.len != 2:
            continue
          let k = item.children[0]
          var nm = ""
          if k.kind == nkIdent:
            nm = k.name
          elif k.kind == nkLitString:
            nm = k.valStr
          if nm.len > 0:
            addSymbol(syms, defs, nm, path, rel, item.children[1], doc,
              item.ln)
        continue
      if lhs.kind == nkDotExpr and lhs.children.len == 2 and
          lhs.children[1].kind == nkIdent:
        let base = lhs.children[0]
        if (base.kind == nkIdent and base.name == "exports") or
            isModuleExports(base):
          addSymbol(syms, defs, lhs.children[1].name, path, rel, rhs, doc,
            lhs.ln)
          continue
      continue
    pending = ""
  (syms, "")

const cssText = """
:root{color-scheme:light dark;--bg:#ffffff;--fg:#1f2328;--muted:#59636e;--card:#f6f8fa;--border:#d1d9e0;--accent:#0550ae}
@media (prefers-color-scheme:dark){:root{--bg:#0d1117;--fg:#e6edf3;--muted:#8b949e;--card:#161b22;--border:#30363d;--accent:#79c0ff}}
*{box-sizing:border-box}
body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif;background:var(--bg);color:var(--fg);margin:0;line-height:1.6}
.wrap{max-width:960px;margin:0 auto;padding:2rem 1.25rem 4rem}
header.top{border-bottom:1px solid var(--border);padding-bottom:1rem;margin-bottom:2rem}
header.top h1{margin:0 0 .25rem;font-size:1.8rem}
header.top p{margin:.25rem 0;color:var(--muted)}
.badge{display:inline-block;font-size:.72rem;font-weight:600;border:1px solid var(--border);border-radius:2em;padding:.05em .6em;margin-left:.5em;vertical-align:middle;color:var(--muted)}
.badge.priv{color:#b35900;border-color:#b35900}
.badge.dep{color:#a40e26;border-color:#a40e26}
.sym{background:var(--card);border:1px solid var(--border);border-radius:8px;padding:1rem 1.25rem;margin:0 0 1.25rem}
.sym h2{margin:0 0 .15rem;font-size:1.2rem;font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
.sym .meta{color:var(--muted);font-size:.82rem;margin-bottom:.6rem}
.sym p.desc{margin:.5rem 0}
table.params{border-collapse:collapse;width:100%;font-size:.9rem;margin:.5rem 0}
table.params th,table.params td{border:1px solid var(--border);padding:.35rem .6rem;text-align:left;vertical-align:top}
table.params th{background:var(--card)}
code.inline{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.88em}
pre.code{background:var(--bg);border:1px solid var(--border);border-radius:6px;padding:.75rem 1rem;overflow-x:auto;font-size:.85rem;line-height:1.5}
pre.code code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;white-space:pre}
.code .string{color:#0a7d33}
.code .int,.code .float,.code .bigint{color:#0550ae}
.code .comment,.code .doc_comment{color:#59636e;font-style:italic}
.code .regex{color:#cf222e}
.code .ident:not([class="ident"]){font-weight:600;color:#8250df}
@media (prefers-color-scheme:dark){.code .string{color:#7ee787}.code .int,.code .float,.code .bigint{color:#79c0ff}.code .comment,.code .doc_comment{color:#8b949e}.code .regex{color:#ff9e64}.code .ident:not([class="ident"]){color:#d2a8ff}}
footer{color:var(--muted);font-size:.82rem;margin-top:3rem;border-top:1px solid var(--border);padding-top:1rem}
"""

proc symbolJson(s: DocSymbol): JsonNode =
  ## One symbol as a JSON object (highlight fragments included so
  ## json-based docs need no client highlighter either).
  var obj = %*{
    "name": s.name,
    "kind": s.kind,
    "file": s.file,
    "line": s.line,
    "signature": s.signature,
    "signatureHtml": s.signatureHtml,
    "description": s.description,
    "returnsType": s.returnsType,
    "returns": s.returns,
    "deprecated": s.deprecated,
    "deprecatedMsg": s.deprecatedMsg,
    "private": s.isPrivate,
  }
  var ps = newJArray()
  for p in s.params:
    ps.add(%*{"name": p.name, "type": p.typ, "optional": p.optional,
      "description": p.description})
  obj["params"] = ps
  var es = newJArray()
  for e in s.examples:
    es.add(%e)
  obj["examples"] = es
  var hs = newJArray()
  for h in s.examplesHtml:
    hs.add(%h)
  obj["examplesHtml"] = hs
  obj

proc buildJson(pkg: tuple[name, version, descr: string];
    syms: seq[DocSymbol]): string =
  ## The `docgen.json` document.
  var root = %*{
    "generator": "carne gen docs",
    "package": {"name": pkg.name, "version": pkg.version,
      "description": pkg.descr},
  }
  var arr = newJArray()
  for s in syms:
    arr.add(symbolJson(s))
  root["symbols"] = arr
  pretty(root) & "\n"

proc buildHtml(pkg: tuple[name, version, descr: string];
    syms: seq[DocSymbol]): string =
  ## One static page. No <script>: all color comes from sweetsyntax spans
  ## plus the bundled stylesheet.
  var b = ""
  b.add("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n")
  b.add("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n")
  b.add("<title>" & escapeHtml(pkg.name) & " API reference</title>\n")
  b.add("<link rel=\"stylesheet\" href=\"assets/style.css\">\n</head>\n<body>\n")
  b.add("<div class=\"wrap\">\n<header class=\"top\">\n<h1>" &
    escapeHtml(pkg.name) & " API reference</h1>\n")
  if pkg.version.len > 0:
    b.add("<p>version " & escapeHtml(pkg.version) & "</p>\n")
  if pkg.descr.len > 0:
    b.add("<p>" & escapeHtml(pkg.descr) & "</p>\n")
  b.add("<p>" & $syms.len & " exported symbol" &
    (if syms.len == 1: "" else: "s") & "</p>\n</header>\n")
  var byFile = initTable[string, seq[DocSymbol]]()
  var order: seq[string] = @[]
  for s in syms:
    if s.file notin byFile:
      byFile[s.file] = @[]
      order.add(s.file)
    byFile[s.file].add(s)
  for f in order:
    b.add("<h2>" & escapeHtml(f) & "</h2>\n")
    for s in byFile[f]:
      b.add("<section class=\"sym\">\n<h2>" & escapeHtml(s.name))
      if s.isPrivate:
        b.add("<span class=\"badge priv\">private</span>")
      if s.deprecated:
        b.add("<span class=\"badge dep\">deprecated</span>")
      b.add("</h2>\n")
      b.add("<div class=\"meta\">" & escapeHtml(s.kind) & " · " &
        escapeHtml(s.file) & ":" & $s.line & "</div>\n")
      b.add("<pre class=\"code\"><code>" & s.signatureHtml &
        "</code></pre>\n")
      if s.description.len > 0:
        b.add("<p class=\"desc\">" & escapeHtml(s.description) & "</p>\n")
      if s.deprecated and s.deprecatedMsg.len > 0:
        b.add("<p class=\"desc\">Deprecated: " &
          escapeHtml(s.deprecatedMsg) & "</p>\n")
      if s.params.len > 0:
        b.add("<table class=\"params\">\n<tr><th>param</th><th>type</th><th></th></tr>\n")
        for p in s.params:
          b.add("<tr><td><code class=\"inline\">" & escapeHtml(p.name) &
            "</code></td><td><code class=\"inline\">" &
            escapeHtml(p.typ) & "</code></td><td>" &
            escapeHtml(p.description) & "</td></tr>\n")
        b.add("</table>\n")
      if s.returns.len > 0 or s.returnsType.len > 0:
        b.add("<p class=\"desc\">returns")
        if s.returnsType.len > 0:
          b.add(" <code class=\"inline\">" & escapeHtml(s.returnsType) &
            "</code>")
        if s.returns.len > 0:
          b.add(" " & escapeHtml(s.returns))
        b.add("</p>\n")
      for h in s.examplesHtml:
        b.add("<pre class=\"code\"><code>" & h & "</code></pre>\n")
      b.add("</section>\n")
  b.add("<footer>generated by carne gen docs</footer>\n</div>\n</body>\n</html>\n")
  b

proc docsCommand*(dir, formatStr, outDir, entry: string): int =
  ## `carne gen docs` entry point. Returns the process exit code.
  var format = dfAll
  try:
    format = parseFormat(formatStr)
  except DocsError as e:
    displayError(e.msg)
    return 1
  if outDir.strip().len == 0:
    displayError("option --out needs a value")
    return 1
  let pkg =
    try:
      packageIdentity(dir)
    except DocsError as e:
      displayError(e.msg)
      return 1
  let files =
    try:
      discoverJsFiles(dir, entry.strip(), outDir.strip())
    except DocsError as e:
      displayError(e.msg)
      return 1
  if files.len == 0:
    displayError("no JavaScript files found" &
      (if entry.len > 0: ": " & entry else: " in " & dir))
    return 1
  var syms: seq[DocSymbol] = @[]
  var parsed = 0
  for path in files:
    let rel = relativePath(path, dir)
    let (got, warned) = extractFile(path, rel)
    if warned.len > 0:
      displayWarning(warned)
      continue
    inc parsed
    syms.add(got)
  if parsed == 0:
    displayError("no JavaScript files could be parsed")
    return 1
  syms.sort(proc(a, b: DocSymbol): int =
    let c = cmp(a.file, b.file)
    if c != 0: c else: cmp(a.line, b.line))
  for s in syms.mitems():
    s.signatureHtml = highlightJs(s.signature)
    s.examplesHtml = @[]
    for e in s.examples:
      s.examplesHtml.add(highlightJs(e))
  let outAbs = if isAbsolute(outDir.strip()): outDir.strip()
    else: dir / outDir.strip()
  try:
    createDir(outAbs)
  except OSError, IOError:
    displayError("cannot create " & outAbs & ": " & getCurrentExceptionMsg())
    return 1
  if format in {dfJson, dfAll}:
    try:
      writeFile(outAbs / "docgen.json", buildJson(pkg, syms))
    except OSError, IOError:
      displayError("cannot write docgen.json: " & getCurrentExceptionMsg())
      return 1
  if format in {dfHtml, dfAll}:
    try:
      writeFile(outAbs / "index.html", buildHtml(pkg, syms))
      createDir(outAbs / "assets")
      writeFile(outAbs / "assets" / "style.css", cssText)
    except OSError, IOError:
      displayError("cannot write HTML output: " & getCurrentExceptionMsg())
      return 1
  displaySuccess("documented " & $syms.len & " symbol" &
    (if syms.len == 1: "" else: "s") & " from " & $parsed & " file" &
    (if parsed == 1: "" else: "s") & " in " & outAbs)
  0
