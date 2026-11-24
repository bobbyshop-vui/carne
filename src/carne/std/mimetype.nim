# Carne std/mimetype: MIME type lookup via mimedb.
#
#   const mimetype = require("std/mimetype");
#   mimetype.lookup("html")       -> "text/html"
#   mimetype.lookup(".PNG")       -> "image/png"
#   mimetype.lookup("nope")       -> null
#   mimetype.info("text/html")
#     -> {source: "iana", extensions: ["html", "htm", "shtml"],
#         compressible: true}
#   mimetype.info("nope/x")       -> null
#   mimetype.isExtension("html")  -> true
#   mimetype.has("text/html")     -> true
#   mimetype.charset("application/json") -> "UTF-8"
#   mimetype.charset("image/png") -> null
#
# Extensions accept a leading dot and any case; MIME types match
# exactly (lowercase). `charset` reflects the bundled mimedb
# snapshot: only the 41 types carrying a default charset answer,
# everything else is null.

import std/options

import javascriptcore

import pkg/mimedb

import ../bridge

const mimeCharsets = [
  ("application/3gpdash-qoe-report+xml", "UTF-8"),
  ("application/beep+xml", "UTF-8"),
  ("application/cda+xml", "UTF-8"),
  ("application/elm+json", "UTF-8"),
  ("application/emergencycalldata.cap+xml", "UTF-8"),
  ("application/fhir+json", "UTF-8"),
  ("application/fhir+xml", "UTF-8"),
  ("application/hl7v2+xml", "UTF-8"),
  ("application/im-iscomposing+xml", "UTF-8"),
  ("application/javascript", "UTF-8"),
  ("application/json", "UTF-8"),
  ("application/manifest+json", "UTF-8"),
  ("application/msc-ivr+xml", "UTF-8"),
  ("application/msc-mixer+xml", "UTF-8"),
  ("application/news-checkgroups", "US-ASCII"),
  ("application/news-groupinfo", "US-ASCII"),
  ("application/pidf+xml", "UTF-8"),
  ("application/pidf-diff+xml", "UTF-8"),
  ("application/poc-settings+xml", "UTF-8"),
  ("application/prs.cyn", "7-BIT"),
  ("application/vnd.fdsn.stationxml+xml", "XML-BASED"),
  ("application/vnd.omads-email+xml", "UTF-8"),
  ("application/vnd.omads-file+xml", "UTF-8"),
  ("application/vnd.omads-folder+xml", "UTF-8"),
  ("application/vnd.syncml+xml", "UTF-8"),
  ("application/vnd.syncml.dm+wbxml", "UTF-8"),
  ("application/vnd.syncml.dm+xml", "UTF-8"),
  ("application/vnd.syncml.dmddf+xml", "UTF-8"),
  ("application/vnd.syncml.dmtnds+xml", "UTF-8"),
  ("application/vnd.wap.wbxml", "UTF-8"),
  ("text/css", "UTF-8"),
  ("text/javascript", "UTF-8"),
  ("text/n3", "UTF-8"),
  ("text/parameters", "UTF-8"),
  ("text/provenance-notation", "UTF-8"),
  ("text/turtle", "UTF-8"),
  ("text/vnd.debian.copyright", "UTF-8"),
  ("text/vnd.esmertec.theme-descriptor", "UTF-8"),
  ("text/vnd.sun.j2me.app-descriptor", "UTF-8"),
  ("text/vnd.trolltech.linguist", "UTF-8"),
  ("text/vtt", "UTF-8"),
]

proc mimeCharset(mimeType: string): Option[string] =
  ## Bundled snapshot of mimedb defaults (exact lowercase match).
  ## Returns none when the type is unknown or carries no charset.
  if not hasMimeType(mimeType):
    return none(string)
  for (name, cs) in mimeCharsets:
    if name == mimeType:
      return some(cs)
  none(string)

## Builds the std/mimetype namespace object.
init proc(module: Module) =
  exportObject:

    module.registerFn lookup(ext: string):
      ## mimetype.lookup(ext) -> MIME type string or null
      let t = getMimeType(ext)
      if t.isSome:
        toJS(ctx, t.get())
      else:
        JSValueMakeNull(ctx)

    module.registerFn info(mimeType: string):
      ## mimetype.info(type) -> {source, extensions, compressible} or null
      let i = getMimeInfo(mimeType)
      if i.isSome:
        let info = i.get()
        let opt = some(info)
        let obj = newObject(ctx)
        if not setPropChecked(ctx, obj, "source",
            toJS(ctx, $opt.getSource()), "info", exception):
          return nil
        if not setPropChecked(ctx, obj, "compressible",
            toJS(ctx, opt.isCompressible()), "info", exception):
          return nil
        var vals: seq[JSValueRef] = @[]
        let known = opt.getExtensions()
        if known.isSome:
          for e in known.get():
            vals.add(toJS(ctx, e))
        let exts = makeJSArray(ctx, vals)
        if exts == nil:
          throwError(ctx, "info: could not convert result to JS",
            exception)
          return nil
        if not setPropChecked(ctx, obj, "extensions", exts, "info",
            exception):
          return nil
        obj
      else:
        JSValueMakeNull(ctx)

    module.registerFn isExtension(ext: string):
      ## mimetype.isExtension(ext) -> bool
      toJS(ctx, isExtension(ext))

    module.registerFn has(mimeType: string):
      ## mimetype.has(type) -> bool
      toJS(ctx, hasMimeType(mimeType))

    module.registerFn charset(mimeType: string):
      ## mimetype.charset(type) -> default charset string or null
      let cs = mimeCharset(mimeType)
      if cs.isSome:
        toJS(ctx, cs.get())
      else:
        JSValueMakeNull(ctx)
