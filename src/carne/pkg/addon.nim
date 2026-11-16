# Carne native addon loading: `require()` of `.so`/`.dylib`/`.node`.
#
# Addons are Nim shared libraries built against `carne/api/addon`
# (`nim c --app:lib --threads:on`). They expose pluginkit-shaped
# lifecycle exports (`plugin_get_manifest`, `plugin_init`,
# `plugin_deinit`) plus the carne entry points
# (`carne_addon_carne_version`, `carne_addon_init`). Loading is once
# per process per library (`plugin_init` runs the Nim runtime a single
# time); every JS context gets a fresh exports object from
# `carne_addon_init`, cached in `rt.instances` like any other module.
# There is no unload: `dlclose` of a Nim library with a live GC is
# asking for crashes, and Node does not unload either.
#
# Threading: http workers resolve concurrently, so the process-wide
# library table is lock-guarded. Per-context exports need no lock.

import std/[dynlib, locks, os, strutils, tables]

import pkg/semver
import pkg/pluginkit

import javascriptcore

import ../bridge
import ../cli

const addonExts* = [".addon", ".so", ".dylib", ".node"]
  ## Loadable native addon extensions. `.addon` is the canonical,
  ## platform-independent name (`carne build` emits it); platform
  ## files and Node-style `.node` load as-is.

type
  CarneAddonInitFn* = proc(ctx: JSContextRef;
    exports: JSObjectRef): cint {.cdecl.}
    ## `carne_addon_init`: fills one fresh exports object per context.
  CarneAddonVersionFn* = proc(): cstring {.cdecl.}
    ## `carne_addon_carne_version`: host carne version built against.

var addonLibs = initTable[string, LibHandle]()
  ## Real path -> loaded library. Written once per library at load,
  ## read-only afterwards; guarded by addonLock for worker threads.

var addonLock: Lock
var addonLockState = 0

proc ensureAddonLock() =
  if addonLockState != 2:
    if addonLockState == 0:
      addonLockState = 1
      initLock(addonLock)
      addonLockState = 2
    else:
      while addonLockState != 2:
        cpuRelax()

proc isAddonPath*(path: string): bool =
  ## True when `path` names a native addon by extension.
  let ext = splitFile(path).ext
  for e in addonExts:
    if ext == e:
      return true
  false

proc insideDir*(root, candidate: string): bool =
  ## True when `candidate` resolves inside `root` (both through
  ## realpath, so symlinks pointing out fail closed). Non-existent
  ## paths fail closed too.
  try:
    let r = expandFilename(root)
    let p = expandFilename(candidate)
    p == r or p.startsWith(r & DirSep)
  except OSError:
    false

proc hostCarneMajor(): int =
  ## Major of the running binary's version (carne.nimble, via cli).
  try:
    parseVersion(versionStr).major
  except CatchableError:
    -1

proc loadAddonFile*(ctx: JSContextRef; rt: Runtime; spec, path: string;
    exception: ptr JSValueRef): JSValueRef =
  ## dlopens `path`, version-checks it and returns its exports object.
  ## `spec` is the require cache key (absolute path for relative
  ## requires, the original spec for `pkg/` ones). Callers guarantee
  ## containment (requireRelative checks insideDir, pkg subpaths come
  ## from resolvePkgImport's containedHit); this proc still fails
  ## closed on unreadable files and invalid libraries.
  if '\0' in path:
    throwError(ctx, "require: invalid addon path \"" & spec & "\"",
      exception)
    return nil
  var real = ""
  try:
    real = expandFilename(path)
  except OSError as e:
    throwError(ctx, "require: cannot read \"" & spec & "\": " & e.msg,
      exception)
    return nil
  if not fileExists(real):
    throwError(ctx, "require: cannot read \"" & spec & "\"", exception)
    return nil
  ensureAddonLock()
  acquire(addonLock)
  try:
    if addonLibs.hasKey(real):
      let initAddon = cast[CarneAddonInitFn](
        addonLibs[real].symAddr("carne_addon_init"))
      if initAddon == nil:
        throwError(ctx, "require: addon \"" & spec &
          "\" is not a carne addon (missing carne_addon_init)",
          exception)
        return nil
      let exportsObj = newObject(ctx)
      if initAddon(ctx, exportsObj) != 0:
        throwError(ctx, "require: failed to initialize \"" & spec & "\"",
          exception)
        return nil
      rt.instances[spec] = exportsObj
      return exportsObj
    let lib = loadLib(real)
    if lib == nil:
      throwError(ctx, "require: could not load addon \"" & spec & "\"",
        exception)
      return nil
    let getManifest = cast[plugin_get_manifest_fn](
      lib.symAddr("plugin_get_manifest"))
    let pluginInit = cast[plugin_init_fn](lib.symAddr("plugin_init"))
    let addonInit = cast[CarneAddonInitFn](
      lib.symAddr("carne_addon_init"))
    let addonVersion = cast[CarneAddonVersionFn](
      lib.symAddr("carne_addon_carne_version"))
    if getManifest == nil or pluginInit == nil or addonInit == nil or
        addonVersion == nil:
      unloadLib(lib)
      throwError(ctx, "require: addon \"" & spec &
        "\" is not a carne addon (built with carne/api/addon?)",
        exception)
      return nil
    var mf: PluginManifest
    if getManifest(addr mf) != 0:
      unloadLib(lib)
      throwError(ctx, "require: addon \"" & spec &
        "\" manifest read failed", exception)
      return nil
    if mf.abiVersion != PluginAbiVersion:
      unloadLib(lib)
      throwError(ctx, "require: addon \"" & spec &
        "\" ABI mismatch (expected " & $PluginAbiVersion & ", got " &
        $mf.abiVersion & ")", exception)
      return nil
    let built = $addonVersion()
    var builtMajor = -1
    var builtMinor = -1
    try:
      let v = parseVersion(built)
      builtMajor = v.major
      builtMinor = v.minor
    except CatchableError:
      discard
    let running = hostCarneMajor()
    if builtMajor < 0 or builtMajor != running:
      unloadLib(lib)
      throwError(ctx, "require: addon \"" & spec &
        "\" built for carne " & built & ", running " & versionStr &
        " (major mismatch)", exception)
      return nil
    try:
      if parseVersion(versionStr).minor != builtMinor:
        stderr.writeLine("Warning: addon \"" & spec & "\" built for " &
          "carne " & built & ", running " & versionStr &
          " (minor drift)")
    except CatchableError:
      discard
    if pluginInit() != 0:
      unloadLib(lib)
      throwError(ctx, "require: failed to initialize \"" & spec & "\"",
        exception)
      return nil
    let exportsObj = newObject(ctx)
    if addonInit(ctx, exportsObj) != 0:
      unloadLib(lib)
      throwError(ctx, "require: failed to initialize \"" & spec & "\"",
        exception)
      return nil
    addonLibs[real] = lib
    rt.instances[spec] = exportsObj
    return exportsObj
  finally:
    release(addonLock)
