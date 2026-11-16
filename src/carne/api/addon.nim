# Carne native addon author API: build `.so`/`.dylib` addons in Nim.
#
#   import carne/api/addon
#
#   newAddon("hello", "1.0.0"):
#     exportObject:
#       registerFn add(a: int, b: int):
#         ## add(a, b) -> number
#         return toJS(ctx, a + b)
#
# Compile with `nim c --app:lib` (plus `--threads:on`). The macro
# generates pluginkit-shaped lifecycle exports (`plugin_get_manifest`,
# `plugin_init`, `plugin_deinit` — so any pluginkit host can load the
# library too) plus the carne entry points (`carne_addon_carne_version`,
# `carne_addon_init`). `registerFn` headers take the exact same
# parameter types as std modules (see bridge.registerFn); arity and
# type checks are generated, and the body starts with the bindings in
# scope plus `ctx`. No Nim exception may escape a callback: report
# failures through `throwError` like std modules do.

import std/macros

import pkg/semver
import pkg/pluginkit
export pluginkit

import ../bridge
export bridge
import javascriptcore
export javascriptcore
import ../cli

proc addonVersionOk(v: string): bool =
  ## True when `v` is exact semver (ranges rejected, like package.json).
  try:
    discard parseVersion(v)
    true
  except CatchableError:
    false

proc exportPragma(): NimNode =
  ## `{.exportc, cdecl, dynlib.}` for one shared-library entry point.
  result = newNimNode(nnkPragma)
  result.add(newIdentNode("exportc"))
  result.add(newIdentNode("cdecl"))
  result.add(newIdentNode("dynlib"))

proc entryProc(name: string; formal, body: NimNode): NimNode =
  ## One `proc name*(...): ... {.exportc, cdecl, dynlib.}` entry point.
  result = newNimNode(nnkProcDef)
  result.add(newIdentNode(name).postfix("*"))
  result.add(newEmptyNode())
  result.add(newEmptyNode())
  result.add(formal)
  result.add(exportPragma())
  result.add(newEmptyNode())
  result.add(body)

macro newAddon*(name: untyped; version: untyped; body: untyped): untyped =
  ## Defines a native addon. `name` and `version` are string literals
  ## (version must be exact semver); the body holds one `exportObject:`
  ## block with bare `registerFn` / `property` members and optional
  ## init-time statements. Generates the shared-library entry points;
  ## one addon per module.
  if name.kind != nnkStrLit:
    error("newAddon expects the addon name as a string literal", name)
  if version.kind != nnkStrLit:
    error("newAddon expects the addon version as an exact semver " &
      "string literal", version)
  let addonName = name.strVal
  let addonVersion = version.strVal
  if addonName.len == 0:
    error("newAddon needs a non-empty name", name)
  if not addonVersionOk(addonVersion):
    error("newAddon version must be exact semver, got \"" & addonVersion &
      "\"", version)
  if body.kind != nnkStmtList:
    error("newAddon expects an `exportObject:` block", body)
  var members: NimNode = nil
  for stmt in body:
    if stmt.kind == nnkCommentStmt:
      continue
    if stmt.kind in {nnkCommand, nnkCall} and stmt.len == 2 and
        stmt[0].kind == nnkIdent and stmt[0].strVal == "exportObject":
      if members != nil:
        error("newAddon takes a single `exportObject:` block", stmt)
      if stmt[1].kind != nnkStmtList:
        error("exportObject takes a single block", stmt)
      members = stmt[1]
    else:
      error("only `exportObject:` is allowed directly in newAddon", stmt)
  if members == nil:
    error("newAddon needs an `exportObject:` block with at least one " &
      "registerFn member", body)

  let ctxId = newIdentNode("ctx")
  let exportsId = newIdentNode("exports")
  let exSym = genSym(nskVar, "ex")
  let initBody = newStmtList()
  var fnCount = 0
  result = newStmtList()
  for member in members:
    if member.kind == nnkCommentStmt:
      continue
    if member.kind in {nnkCommand, nnkCall} and member.len == 3 and
        member[0].kind == nnkIdent and member[0].strVal == "registerFn":
      let parsed = parseHeader(member[1], "registerFn")
      let fname = parsed.fname
      result.add(buildCallbackFn(fname, "ctx", copy(member[2]),
        parsed.params))
      initBody.add(newCall("setProp", ctxId, exportsId,
        newStrLitNode(fname),
        newCall("makeFunction", ctxId, newStrLitNode(fname),
          newIdentNode(fname)),
        nnkCommand.newTree(newIdentNode("addr"), exSym)))
      inc fnCount
    elif member.kind in {nnkCommand, nnkCall} and member.len == 2 and
        member[0].kind == nnkIdent and member[0].strVal == "property":
      if member[1].kind != nnkExprEqExpr:
        error("property expects `name = value`", member)
      let key = member[1][0]
      if key.kind notin {nnkIdent, nnkStrLit}:
        error("property name must be an identifier or string", member)
      initBody.add(newCall("setProp", ctxId, exportsId,
        newStrLitNode(key.strVal),
        newCall("propToJS", ctxId, copy(member[1][1])),
        nnkCommand.newTree(newIdentNode("addr"), exSym)))
    else:
      # Bare init-time statement: runs inside carne_addon_init.
      initBody.add(copy(member))
  if fnCount == 0:
    error("newAddon needs at least one `registerFn` member", body)

  # Manifest shared by the pluginkit-shaped lifecycle exports. A
  # gensym keeps it collision-free; both declaration and reader use
  # the same node.
  let manifSym = genSym(nskVar, "gAddonManifest")
  result.add(nnkVarSection.newTree(newIdentDefs(manifSym,
    newIdentNode("PluginManifest"),
    nnkObjConstr.newTree(newIdentNode("PluginManifest"),
      nnkExprColonExpr.newTree(newIdentNode("abiVersion"),
        newIdentNode("PluginAbiVersion")),
      nnkExprColonExpr.newTree(newIdentNode("name"),
        newCall("cstring", newStrLitNode(addonName))),
      nnkExprColonExpr.newTree(newIdentNode("version"),
        newCall("cstring", newStrLitNode(addonVersion))),
      nnkExprColonExpr.newTree(newIdentNode("nimVersion"),
        newCall("cstring", newIdentNode("NimVersion")))))))

  # proc NimMain {.cdecl, importc.}
  let nimMain = newNimNode(nnkProcDef)
  nimMain.add(newIdentNode("NimMain"))
  nimMain.add(newEmptyNode())
  nimMain.add(newEmptyNode())
  nimMain.add(nnkFormalParams.newTree(newEmptyNode()))
  nimMain.add(nnkPragma.newTree(newIdentNode("cdecl"),
    newIdentNode("importc")))
  nimMain.add(newEmptyNode())
  nimMain.add(newStmtList())
  result.add(nimMain)

  # plugin_get_manifest: pluginkit hosts (and our loader) read this.
  let outMan = newIdentNode("outManifest")
  result.add(entryProc("plugin_get_manifest",
    nnkFormalParams.newTree(newIdentNode("cint"),
      nnkIdentDefs.newTree(outMan,
        nnkPtrTy.newTree(newIdentNode("PluginManifest")),
        newEmptyNode())),
    newStmtList(
      nnkIfStmt.newTree(nnkElifBranch.newTree(
        newCall("isNil", outMan),
        newStmtList(nnkReturnStmt.newTree(newLit(1))))),
      nnkAsgn.newTree(
        nnkDerefExpr.newTree(outMan), manifSym),
      nnkReturnStmt.newTree(newLit(0)))))

  # plugin_init runs the Nim runtime; the loader calls it once per
  # process before the first carne_addon_init.
  result.add(entryProc("plugin_init",
    nnkFormalParams.newTree(newIdentNode("cint")),
    newStmtList(
      newCall("NimMain"),
      nnkReturnStmt.newTree(newLit(0)))))

  result.add(entryProc("plugin_deinit",
    nnkFormalParams.newTree(newEmptyNode()),
    newStmtList(newCall("GC_FullCollect"))))

  # carne_addon_carne_version: the host carne version this addon was
  # built against (cli.versionStr reads carne.nimble at the addon's
  # compile time). The loader major-matches it.
  result.add(entryProc("carne_addon_carne_version",
    nnkFormalParams.newTree(newIdentNode("cstring")),
    newStmtList(nnkReturnStmt.newTree(
      newCall("cstring", newStrLitNode(versionStr))))))

  # carne_addon_init: fills one fresh exports object per JS context.
  let initStmts = newStmtList()
  initStmts.add(nnkVarSection.newTree(
    newIdentDefs(exSym, newIdentNode("JSValueRef"), newNilLit())))
  for s in initBody:
    initStmts.add(s)
  initStmts.add(nnkIfStmt.newTree(nnkElifBranch.newTree(
    nnkInfix.newTree(newIdentNode("!="), exSym, newNilLit()),
    newStmtList(nnkReturnStmt.newTree(newLit(1))))))
  initStmts.add(nnkReturnStmt.newTree(newLit(0)))
  result.add(entryProc("carne_addon_init",
    nnkFormalParams.newTree(newIdentNode("cint"),
      nnkIdentDefs.newTree(ctxId, newIdentNode("JSContextRef"),
        newEmptyNode()),
      nnkIdentDefs.newTree(exportsId, newIdentNode("JSObjectRef"),
        newEmptyNode())),
    initStmts))
