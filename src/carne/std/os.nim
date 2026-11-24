# Carne std/os: synchronous OS utilities (files, dirs, process).
#
#   const os = require("std/os");
#   os.readFile(path)         -> string (throws on IOError)
#   os.readFileBytes(path)    -> Uint8Array (mmap zero-copy, throws on IOError)
#   os.writeFile(path, data)  -> undefined
#   os.writeFileBytes(path, data) -> undefined (data: string | Uint8Array)
#   os.appendFile(path, data) -> undefined
#   os.exists(path)           -> bool (files and dirs)
#   os.isFile(path)           -> bool
#   os.isDir(path)            -> bool
#   os.readDir(path)          -> [{name, kind}] (kind: file|dir|symlink)
#   os.mkdir(path[, recursive]) -> undefined
#   os.remove(path)           -> undefined (files only)
#   os.removeDir(path[, recursive]) -> undefined
#   os.copy(src, dst)         -> undefined (files)
#   os.move(src, dst)         -> undefined (files and dirs)
#   os.stat(path)             -> {size, kind, mtimeMs, atimeMs, mode}
#   os.chmod(path, mode)      -> undefined (mode: e.g. 420 for 0o644)
#   os.symlink(target, path)  -> undefined (create a symlink at path)
#   os.readLink(path)         -> string (symlink target)
#   os.isSymlink(path)        -> bool
#   os.tmpdir()               -> string
#   os.homedir()              -> string
#   os.configDir()            -> string
#   os.cacheDir()             -> string
#   os.pid()                  -> int
#   os.cpuCount()             -> int (logical processors, >= 1)
#   os.exec(cmd)              -> {code, output} (blocks the loop)
#   os.spawn(cmd[, {onStdout, onStderr}])
#     -> Promise<{code, stdout, stderr}> (async, loop-friendly: chunks
#        stream to the callbacks while the process runs; stdin arrives
#        closed, so readers see EOF)
#
# Everything throws a JS Error on failure. exec blocks the
# event loop like any sync call: fine in scripts, stalls servers.
# spawn never blocks: it polls the pipes on the shared loop and
# settles the promise on exit.

import std/[algorithm, json, memfiles, os, osproc, streams, times]

when not defined(windows):
  import std/posix

import javascriptcore

from powpow/loop import Loop, TimerId, addInterval, cancelTimer, stop

import ../bridge

proc kindName(pc: PathComponent): string =
  case pc
  of pcFile: "file"
  of pcDir: "dir"
  of pcLinkToFile, pcLinkToDir: "symlink"

proc toMs(t: times.Time): int64 =
  int64(t.toUnix()) * 1000 + int64(t.nanosecond div 1_000_000)

proc statToJson(info: FileInfo): JsonNode =
  result = newJObject()
  result["size"] = newJInt(info.size)
  result["kind"] = %kindName(info.kind)
  result["mtimeMs"] = %toMs(info.lastWriteTime)
  result["atimeMs"] = %toMs(info.lastAccessTime)

proc permsToMode(perms: set[FilePermission]): int =
  ## 9-bit Unix mode from a permission set (e.g. 0o644).
  if fpUserRead in perms: result += 0o400
  if fpUserWrite in perms: result += 0o200
  if fpUserExec in perms: result += 0o100
  if fpGroupRead in perms: result += 0o040
  if fpGroupWrite in perms: result += 0o020
  if fpGroupExec in perms: result += 0o010
  if fpOthersRead in perms: result += 0o004
  if fpOthersWrite in perms: result += 0o002
  if fpOthersExec in perms: result += 0o001

proc modeToPerms(mode: int): set[FilePermission] =
  ## Permission set from a 9-bit Unix mode (masked with 0o777).
  let m = mode and 0o777
  if (m and 0o400) != 0: result.incl(fpUserRead)
  if (m and 0o200) != 0: result.incl(fpUserWrite)
  if (m and 0o100) != 0: result.incl(fpUserExec)
  if (m and 0o040) != 0: result.incl(fpGroupRead)
  if (m and 0o020) != 0: result.incl(fpGroupWrite)
  if (m and 0o010) != 0: result.incl(fpGroupExec)
  if (m and 0o004) != 0: result.incl(fpOthersRead)
  if (m and 0o002) != 0: result.incl(fpOthersWrite)
  if (m and 0o001) != 0: result.incl(fpOthersExec)

proc mkdirRecursive(path: string) =
  ## createDir through missing parents (no-op when path exists).
  var missing: seq[string] = @[]
  var cur = path
  while cur.len > 0 and not dirExists(cur) and not fileExists(cur):
    missing.add(cur)
    let parent = parentDir(cur)
    if parent == cur:
      break
    cur = parent
  for i in countdown(missing.high, 0):
    createDir(missing[i])

proc removeDirRecursive(path: string) =
  ## Depth-first delete: files first, then dirs deepest-first, then
  ## the root. Symlinked dirs are removed as links, never descended
  ## into (followFilter stays empty).
  var files: seq[string] = @[]
  for p in walkDirRec(path, yieldFilter = {pcFile, pcLinkToFile,
      pcLinkToDir}, followFilter = {}):
    files.add(p)
  var dirs: seq[string] = @[]
  for p in walkDirRec(path, yieldFilter = {pcDir}, followFilter = {}):
    dirs.add(p)
  for f in files:
    removeFile(f)
  dirs.sort(proc(a, b: string): int = cmp(b.len, a.len))
  for d in dirs:
    removeDir(d)
  removeDir(path)

const mmapThreshold = 64 * 1024
  ## readFile maps instead of reading past this size: below it the
  ## mmap syscall + page-table cost exceeds one streaming read, and
  ## the bridge string snapshot (~1us/KB) dominates either way.

const spawnPollMs = 10
  ## spawn pipe poll cadence: chunks surface within ~10ms while each
  ## tick stays a non-blocking drain, never stalling the loop.

type
  SpawnState = ref object
    p: Process
    ctx: JSContextRef
    rt: Runtime
    loop: Loop
    timerId: TimerId
    onOut, onErr: JSObjectRef
    resolveFn, rejectFn: JSObjectRef
    promise: JSValueRef
    outAcc, errAcc: string
    outEof, errEof: bool
    settled: bool

proc decSpawnPending(rt: Runtime) =
  dec rt.pending
  if rt.pending <= 0 and not rt.exitRequested:
    rt.pending = 0
    rt.loop.stop()

when not defined(windows):
  proc setNonBlockFd(fd: FileHandle) =
    ## Best-effort O_NONBLOCK so spawn polls never stall the loop.
    let flags = fcntl(cast[cint](fd), F_GETFL, 0)
    if flags >= 0:
      discard fcntl(cast[cint](fd), F_SETFL, flags or O_NONBLOCK)

  proc readAvailFd(fd: FileHandle; eof: var bool): string =
    ## Non-blocking drain: data read so far, eof when the writer is
    ## gone. EAGAIN just ends the slice; other errors raise.
    eof = false
    const BufSize = 65536
    var buf = newString(BufSize)
    while true:
      let n = read(cast[cint](fd), addr buf[0], BufSize)
      if n > 0:
        result.add(buf[0 ..< n])
      elif n == 0:
        eof = true
        break
      else:
        let e = osLastError()
        if e == OSErrorCode(EAGAIN) or e == OSErrorCode(EWOULDBLOCK):
          break
        raise newException(OSError, "read failed: " & $e)

proc fireSpawnCb(st: SpawnState; fn: JSObjectRef; chunk: string) =
  ## Runs one stdout/stderr chunk callback inside JS. Callback throws
  ## are recorded as uncaught (exit 1 after drain) without killing
  ## the spawn: remaining chunks still stream.
  if fn == nil:
    return
  var ex: JSValueRef = nil
  var arg = toJS(st.ctx, chunk)
  discard JSObjectCallAsFunction(st.ctx, fn, nil, 1, addr arg, addr ex)
  if ex != nil:
    if st.rt.uncaught.len == 0:
      st.rt.uncaught = valueToString(st.ctx, ex)
      st.rt.exitCode = 1

proc settleSpawn(st: SpawnState; code: int; errMsg: string) =
  ## Resolves {code, stdout, stderr} or rejects, then releases the
  ## timer, the process and every protected handle. Idempotent.
  if st.settled:
    return
  st.settled = true
  try:
    st.loop.cancelTimer(st.timerId)
  except CatchableError:
    discard
  try:
    close(st.p)
  except CatchableError:
    discard
  var e2: JSValueRef = nil
  if errMsg == "":
    var node = newJObject()
    node["code"] = %code
    node["stdout"] = %st.outAcc
    node["stderr"] = %st.errAcc
    let v = returnJson(st.ctx, node, "spawn", nil)
    if v == nil:
      let m = toJS(st.ctx, "spawn: could not convert result to JS")
      let errObj = JSObjectMakeError(st.ctx, 1, unsafeAddr m, addr e2)
      var arg = if errObj != nil: errObj else: m
      discard JSObjectCallAsFunction(st.ctx, st.rejectFn, nil, 1,
        addr arg, addr e2)
    else:
      var vv = v
      JSValueProtect(st.ctx, v)
      discard JSObjectCallAsFunction(st.ctx, st.resolveFn, nil, 1,
        addr vv, addr e2)
      JSValueUnprotect(st.ctx, v)
  else:
    let m = toJS(st.ctx, errMsg)
    let errObj = JSObjectMakeError(st.ctx, 1, unsafeAddr m, addr e2)
    var arg = if errObj != nil: errObj else: m
    discard JSObjectCallAsFunction(st.ctx, st.rejectFn, nil, 1,
      addr arg, addr e2)
  if st.onOut != nil:
    JSValueUnprotect(st.ctx, st.onOut)
  if st.onErr != nil:
    JSValueUnprotect(st.ctx, st.onErr)
  JSValueUnprotect(st.ctx, st.promise)
  JSValueUnprotect(st.ctx, st.resolveFn)
  JSValueUnprotect(st.ctx, st.rejectFn)
  decSpawnPending(st.rt)

proc drainSpawnStream(st: SpawnState; isOut: bool) =
  ## One non-blocking drain of a single pipe: accumulate, stream the
  ## chunk to its callback, latch EOF. Read errors fail the spawn.
  when defined(windows):
    discard
  else:
    var eof = false
    let chunk =
      if isOut: readAvailFd(st.p.outputHandle, eof)
      else: readAvailFd(st.p.errorHandle, eof)
    if chunk.len > 0:
      if isOut:
        st.outAcc.add(chunk)
        fireSpawnCb(st, st.onOut, chunk)
      else:
        st.errAcc.add(chunk)
        fireSpawnCb(st, st.onErr, chunk)
    if isOut:
      st.outEof = eof
    else:
      st.errEof = eof

proc pollSpawn(st: SpawnState) =
  ## Loop-tick poll: drain whatever the process wrote, settle with
  ## the exit code once it leaves (final drain first, so no tail
  ## bytes are lost between the last tick and the exit).
  if st.settled:
    return
  try:
    if not st.outEof:
      drainSpawnStream(st, true)
    if not st.errEof:
      drainSpawnStream(st, false)
    let code = peekExitCode(st.p)
    if code != -1:
      if not st.outEof:
        drainSpawnStream(st, true)
      if not st.errEof:
        drainSpawnStream(st, false)
      settleSpawn(st, code, "")
  except CatchableError as e:
    settleSpawn(st, -1, "spawn: " & e.msg)

proc readFileFast(path: string): string =
  ## readFile with an mmap fast path for large regular files. Small,
  ## empty and non-mappable inputs (pipes, proc, dirs) fall back to
  ## readFile, so errors stay byte-identical to the plain call. Raises
  ## IOError/OSError like readFile.
  let size =
    try:
      getFileSize(path)
    except OSError:
      return readFile(path)
  if size <= mmapThreshold:
    return readFile(path)
  var mf: MemFile
  try:
    mf = memfiles.open(path)
  except OSError:
    return readFile(path)
  try:
    if mf.size <= 0:
      result = readFile(path)
    else:
      # Immediate copy + close keeps the truncate-SIGBUS window tiny;
      # the mapping never outlives this call.
      result = newString(mf.size)
      copyMem(addr result[0], mf.mem, mf.size)
  finally:
    mf.close()

## Builds the std/os namespace object.
init proc(module: Module) =
  exportObject:

    module.registerFn readFile(path: string):
      ## os.readFile(path) -> string (throws on IOError)
      try:
        toJS(ctx, readFileFast(path))
      except IOError as e:
        throwError(ctx, "readFile: " & e.msg, exception)
        nil
      except OSError as e:
        throwError(ctx, "readFile: " & e.msg, exception)
        nil

    module.registerFn readFileBytes(path: string):
      ## os.readFileBytes(path) -> Uint8Array (mmap zero-copy, throws on IOError)
      try:
        when not defined(windows):
          let size =
            try:
              getFileSize(path)
            except OSError:
              return toJSUint8Copy(ctx, readFile(path), "readFileBytes",
                exception)
          if size <= 0:
            return toJSUint8Copy(ctx, readFile(path), "readFileBytes",
              exception)
          var mf: MemFile
          try:
            mf = memfiles.open(path)
          except OSError:
            return toJSUint8Copy(ctx, readFile(path), "readFileBytes",
              exception)
          if mf.size <= 0:
            mf.close()
            return toJSUint8Copy(ctx, readFile(path), "readFileBytes",
              exception)
          # Ownership moves to JSC (munmap on GC): never close mf
          # past this point, on success or failure.
          let m = mf.mem
          let s = mf.size
          return toJSUint8Mmap(ctx, m, s, "readFileBytes", exception)
        else:
          return toJSUint8Copy(ctx, readFile(path), "readFileBytes",
            exception)
      except IOError as e:
        throwError(ctx, "readFileBytes: " & e.msg, exception)
        nil
      except OSError as e:
        throwError(ctx, "readFileBytes: " & e.msg, exception)
        nil

    module.registerFn writeFile(path: string, data: string):
      ## os.writeFile(path, data) -> undefined
      try:
        writeFile(path, data)
      except IOError as e:
        throwError(ctx, "writeFile: " & e.msg, exception)
        return nil
      except OSError as e:
        throwError(ctx, "writeFile: " & e.msg, exception)
        return nil
      JSValueMakeUndefined(ctx)

    module.registerFn appendFile(path: string, data: string):
      ## os.appendFile(path, data) -> undefined
      try:
        var f = system.open(path, fmAppend)
        try:
          f.write(data)
        finally:
          f.close()
      except IOError as e:
        throwError(ctx, "appendFile: " & e.msg, exception)
        return nil
      except OSError as e:
        throwError(ctx, "appendFile: " & e.msg, exception)
        return nil
      JSValueMakeUndefined(ctx)

    module.registerFn writeFileBytes(path: string, data: JSValueRef):
      ## os.writeFileBytes(path, data) -> undefined (data: string | Uint8Array)
      var bytes: string
      if not readBytesParam(ctx, data, "writeFileBytes", "data", docBlock,
          exception, bytes):
        return nil
      try:
        writeFile(path, bytes)
      except IOError as e:
        throwError(ctx, "writeFileBytes: " & e.msg, exception)
        return nil
      except OSError as e:
        throwError(ctx, "writeFileBytes: " & e.msg, exception)
        return nil
      JSValueMakeUndefined(ctx)

    module.registerFn exists(path: string):
      ## os.exists(path) -> bool (files and dirs)
      toJS(ctx, fileExists(path) or dirExists(path))

    module.registerFn isFile(path: string):
      ## os.isFile(path) -> bool
      toJS(ctx, fileExists(path))

    module.registerFn isDir(path: string):
      ## os.isDir(path) -> bool
      toJS(ctx, dirExists(path))

    module.registerFn readDir(path: string):
      ## os.readDir(path) -> [{name, kind}]
      var entries = newJArray()
      try:
        for pc, entry in walkDir(path, checkDir = true):
          var obj = newJObject()
          obj["name"] = %entry.extractFilename()
          obj["kind"] = %kindName(pc)
          entries.add(obj)
      except OSError as e:
        throwError(ctx, "readDir: " & e.msg, exception)
        return nil
      returnJson(ctx, entries, "readDir", exception)

    module.registerFn mkdir(path: string, recursive ?: bool):
      ## os.mkdir(path[, recursive]) -> undefined
      try:
        if recursive:
          mkdirRecursive(path)
        else:
          createDir(path)
      except OSError as e:
        throwError(ctx, "mkdir: " & e.msg, exception)
        return nil
      JSValueMakeUndefined(ctx)

    module.registerFn remove(path: string):
      ## os.remove(path) -> undefined (files only)
      try:
        removeFile(path)
      except OSError as e:
        throwError(ctx, "remove: " & e.msg, exception)
        return nil
      JSValueMakeUndefined(ctx)

    module.registerFn removeDir(path: string, recursive ?: bool):
      ## os.removeDir(path[, recursive]) -> undefined
      try:
        if recursive:
          removeDirRecursive(path)
        else:
          removeDir(path)
      except OSError as e:
        throwError(ctx, "removeDir: " & e.msg, exception)
        return nil
      JSValueMakeUndefined(ctx)

    module.registerFn copy(src: string, dst: string):
      ## os.copy(src, dst) -> undefined (files)
      try:
        copyFile(src, dst)
      except OSError as e:
        throwError(ctx, "copy: " & e.msg, exception)
        return nil
      except IOError as e:
        throwError(ctx, "copy: " & e.msg, exception)
        return nil
      JSValueMakeUndefined(ctx)

    module.registerFn move(src: string, dst: string):
      ## os.move(src, dst) -> undefined (files and dirs)
      try:
        moveFile(src, dst)
      except OSError as e:
        throwError(ctx, "move: " & e.msg, exception)
        return nil
      JSValueMakeUndefined(ctx)

    module.registerFn stat(path: string):
      ## os.stat(path) -> {size, kind, mtimeMs, atimeMs, mode}
      try:
        var node = statToJson(getFileInfo(path))
        try:
          node["mode"] = newJInt(permsToMode(getFilePermissions(path)))
        except OSError, IOError:
          node["mode"] = newJInt(0)
        returnJson(ctx, node, "stat", exception)
      except OSError as e:
        throwError(ctx, "stat: " & e.msg, exception)
        nil

    module.registerFn chmod(path: string, mode: int):
      ## os.chmod(path, mode) -> undefined (mode is a Unix mode, e.g. 420 for 0o644)
      if mode < 0 or mode > 0o777:
        throwError(ctx, "chmod: mode out of range (0..511)", exception)
        return nil
      try:
        setFilePermissions(path, modeToPerms(mode))
      except OSError as e:
        throwError(ctx, "chmod: " & e.msg, exception)
        return nil
      except IOError as e:
        throwError(ctx, "chmod: " & e.msg, exception)
        return nil
      JSValueMakeUndefined(ctx)

    module.registerFn symlink(target: string, path: string):
      ## os.symlink(target, path) -> undefined (create a symlink at path)
      try:
        createSymlink(target, path)
      except OSError as e:
        throwError(ctx, "symlink: " & e.msg, exception)
        return nil
      except IOError as e:
        throwError(ctx, "symlink: " & e.msg, exception)
        return nil
      JSValueMakeUndefined(ctx)

    module.registerFn readLink(path: string):
      ## os.readLink(path) -> string (symlink target)
      try:
        toJS(ctx, expandSymlink(path))
      except OSError as e:
        throwError(ctx, "readLink: " & e.msg, exception)
        nil
      except IOError as e:
        throwError(ctx, "readLink: " & e.msg, exception)
        nil

    module.registerFn isSymlink(path: string):
      ## os.isSymlink(path) -> bool
      toJS(ctx, symlinkExists(path))

    module.registerFn tmpdir():
      ## os.tmpdir() -> temp directory path
      try:
        toJS(ctx, getTempDir())
      except OSError as e:
        throwError(ctx, "tmpdir: " & e.msg, exception)
        nil

    module.registerFn homedir():
      ## os.homedir() -> home directory path
      try:
        toJS(ctx, getHomeDir())
      except OSError as e:
        throwError(ctx, "homedir: " & e.msg, exception)
        nil

    module.registerFn configDir():
      ## os.configDir() -> config directory path
      try:
        toJS(ctx, getConfigDir())
      except OSError as e:
        throwError(ctx, "configDir: " & e.msg, exception)
        nil

    module.registerFn cacheDir():
      ## os.cacheDir() -> cache directory path
      try:
        toJS(ctx, getCacheDir())
      except OSError as e:
        throwError(ctx, "cacheDir: " & e.msg, exception)
        nil

    module.registerFn pid():
      ## os.pid() -> current process id
      toJS(ctx, int(getCurrentProcessId()))

    module.registerFn cpuCount():
      ## os.cpuCount() -> logical processor count (>= 1)
      toJS(ctx, max(countProcessors(), 1))

    module.registerFn exec(cmd: string):
      ## os.exec(cmd) -> {code, output} (blocks the loop)
      try:
        let res = execCmdEx(cmd)
        var obj = newJObject()
        obj["code"] = %res.exitCode
        obj["output"] = %res.output
        returnJson(ctx, obj, "exec", exception)
      except OSError as e:
        throwError(ctx, "exec: " & e.msg, exception)
        nil
      except IOError as e:
        throwError(ctx, "exec: " & e.msg, exception)
        nil

    module.registerFn spawn(cmd: string, optsObj ?: JSObjectRef):
      ## os.spawn(cmd[, {onStdout, onStderr}]) -> Promise<{code, stdout, stderr}>
      ## (async and loop-friendly: chunks stream to the callbacks while
      ## the process runs; stdin arrives closed, so readers see EOF)
      var onOut, onErr: JSObjectRef = nil
      if optsObj != nil:
        for (key, dst) in [("onStdout", addr onOut),
            ("onStderr", addr onErr)]:
          var ferr = ""
          let f = getField(ctx, optsObj, key, ferr)
          if ferr != "":
            throwError(ctx, "spawn: options." & key & " " & ferr,
              exception)
            return nil
          case f.kind
          of nvkFunction:
            dst[] = f.raw
          of nvkUndefined, nvkNull:
            discard
          else:
            throwError(ctx, "spawn: options." & key &
              " must be a function, got " & jsTypeName(f.kind), exception)
            return nil
      var p: Process = nil
      try:
        p = startProcess(cmd, options = {poEvalCommand})
        streams.close(p.inputStream)
        when not defined(windows):
          setNonBlockFd(p.outputHandle)
          setNonBlockFd(p.errorHandle)
      except CatchableError as e:
        if p != nil:
          try:
            close(p)
          except CatchableError:
            discard
        throwError(ctx, "spawn: " & e.msg, exception)
        return nil
      var resolveFn, rejectFn: JSObjectRef
      var mkEx: JSValueRef = nil
      let promise = JSObjectMakeDeferredPromise(ctx, addr resolveFn,
        addr rejectFn, addr mkEx)
      if promise == nil or mkEx != nil:
        try:
          close(p)
        except CatchableError:
          discard
        throwError(ctx, "spawn: could not create promise", exception)
        return nil
      let rt = currentRt()
      JSValueProtect(ctx, promise)
      JSValueProtect(ctx, resolveFn)
      JSValueProtect(ctx, rejectFn)
      if onOut != nil:
        JSValueProtect(ctx, onOut)
      if onErr != nil:
        JSValueProtect(ctx, onErr)
      let loop = rt.ensureLoop()
      inc rt.pending
      let st = SpawnState(p: p, ctx: ctx, rt: rt, loop: loop,
        onOut: onOut, onErr: onErr, resolveFn: resolveFn,
        rejectFn: rejectFn, promise: promise)
      st.timerId = loop.addInterval(spawnPollMs,
        proc(id: int) = pollSpawn(st))
      promise
