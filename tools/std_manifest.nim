# tools/std_manifest.nim: regenerate src/carne/std/js/manifest.json.
#
#   clue build tools/std_manifest.nim -o:/tmp/std_manifest && /tmp/std_manifest [--check]
#
# Scans src/carne/std/js/*.js, hashes each file with nimcypher's
# sha256Hex (the same function stdsync.verifySha checks downloads
# against, so script output and runtime verification cannot
# disagree), and reconciles manifest.json: changed hashes updated,
# new files appended alphabetically, deleted entries dropped,
# existing key order kept. Content changes patch-bump the version;
# no changes is a no-op exit 0. --check only reports staleness
# (non-zero exit), never writes. Manifest names are cross-checked
# against stdKnownJs; divergence fails without writing, so the
# fallback list moves in the same commit as the files.

import std/[algorithm, json, os, sequtils, strutils, tables]

import pkg/nimcypher/hash

import carne/pkg/stdsync

proc fail(msg: string) {.noreturn.} =
  stderr.writeLine("std_manifest: " & msg)
  quit(1)

proc bumpPatch(v: string): string =
  let parts = v.split('.')
  if parts.len != 3:
    fail("malformed version \"" & v & "\" (want x.y.z)")
  var nums: array[3, int]
  for i in 0 ..< 3:
    try:
      nums[i] = parseInt(parts[i])
    except ValueError:
      fail("malformed version \"" & v & "\" (want x.y.z)")
    if nums[i] < 0:
      fail("malformed version \"" & v & "\" (want x.y.z)")
  $nums[0] & "." & $nums[1] & "." & $(nums[2] + 1)

proc renderManifest(version: string; names: seq[string];
    files: Table[string, StdFile]): string =
  ## Byte-stable writer: reproduces the committed 2-space style
  ## exactly (trailing newline included), so clean trees stay
  ## diff-free.
  result = "{\n"
  result.add("  \"version\": \"" & version & "\",\n")
  result.add("  \"files\": {\n")
  for i, name in names:
    let e = files[name]
    result.add("    \"" & name & "\": {\n")
    result.add("      \"file\": \"" & e.file & "\",\n")
    result.add("      \"sha256\": \"" & e.sha256 & "\"\n")
    result.add(if i < names.high: "    },\n" else: "    }\n")
  result.add("  }\n}\n")

proc main(checkOnly: bool): int =
  let root = normalizedPath(currentSourcePath.parentDir / "..")
  let jsDir = root / "src" / "carne" / "std" / "js"
  let manifestPath = jsDir / "manifest.json"
  var old: StdManifest
  var docOrder: seq[string] = @[]
  try:
    let src = readFile(manifestPath)
    old = parseStdManifest(src)
    # Table iteration is unordered: take key order from the document
    # so rewrites preserve it.
    for k in parseJson(src)["files"].keys:
      docOrder.add(k)
  except CatchableError as e:
    fail("cannot parse " & manifestPath & " (" & e.msg & ")")
  var onDisk = initTable[string, string]()
  try:
    for kind, path in walkDir(jsDir):
      if kind == pcFile and path.endsWith(".js"):
        onDisk[path.extractFilename().changeFileExt("")] = readFile(path)
  except OSError as e:
    fail("cannot scan " & jsDir & " (" & e.msg & ")")
  var files = initTable[string, StdFile]()
  var added, changed, removed: seq[string] = @[]
  var names: seq[string] = @[]
  for name in docOrder:
    if onDisk.hasKey(name):
      let hex = sha256Hex(onDisk[name]).toLowerAscii()
      files[name] = (file: name & ".js", sha256: hex)
      names.add(name)
      if hex != old.files[name].sha256.strip().toLowerAscii():
        changed.add(name)
    else:
      removed.add(name)
  var fresh = sorted(toSeq(onDisk.keys))
  for name in fresh:
    if name notin files:
      files[name] = (file: name & ".js",
        sha256: sha256Hex(onDisk[name]).toLowerAscii())
      names.add(name)
      added.add(name)
  var known = initTable[string, bool]()
  for k in stdKnownJs:
    known[k] = true
  var drift: seq[string] = @[]
  for name in names:
    if not known.hasKey(name):
      drift.add("manifest has \"" & name & "\" missing from stdKnownJs")
  for k in stdKnownJs:
    if k notin files:
      drift.add("stdKnownJs has \"" & k & "\" missing from manifest/disk")
  if drift.len > 0:
    fail("stdKnownJs drift (update src/carne/pkg/stdsync.nim):\n  " &
      drift.join("\n  "))
  if added.len == 0 and changed.len == 0 and removed.len == 0:
    echo "std manifest up to date (" & old.version & ")"
    return 0
  var detail: seq[string] = @[]
  if changed.len > 0:
    detail.add("updated " & sorted(changed).join(", "))
  if added.len > 0:
    detail.add("added " & sorted(added).join(", "))
  if removed.len > 0:
    detail.add("removed " & sorted(removed).join(", "))
  let version = bumpPatch(old.version)
  if checkOnly:
    echo "std manifest stale (" & old.version & " -> " & version & "): " &
      detail.join("; ")
    return 1
  try:
    writeFile(manifestPath, renderManifest(version, names, files))
  except CatchableError as e:
    fail("cannot write " & manifestPath & " (" & e.msg & ")")
  echo "std manifest " & old.version & " -> " & version & ": " &
    detail.join("; ")
  0

when isMainModule:
  let args = commandLineParams()
  if "--help" in args or "-h" in args:
    echo "usage: std_manifest [--check]"
    quit(0)
  for a in args:
    if a != "--check":
      fail("unknown argument \"" & a & "\" (want --check)")
  quit(main("--check" in args))
