# A hand-rolled "addon" reporting a bogus host carne version.
# Exercises the loader's ABI + major-version checks without newAddon.
import pkg/pluginkit
import javascriptcore

var gManifest = PluginManifest(abiVersion: PluginAbiVersion,
  name: "badver", version: "0.1.0", nimVersion: NimVersion)

proc NimMain {.cdecl, importc.}

{.push exportc, cdecl, dynlib.}
proc plugin_get_manifest*(outManifest: ptr PluginManifest): cint =
  if outManifest.isNil:
    return 1
  outManifest[] = gManifest
  return 0

proc plugin_init*(): cint =
  NimMain()
  return 0

proc plugin_deinit*() =
  GC_FullCollect()

proc carne_addon_carne_version*(): cstring =
  cstring("99.0.0")

proc carne_addon_init*(ctx: JSContextRef; exports: JSObjectRef): cint =
  0
{.pop.}
