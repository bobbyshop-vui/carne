import std/monotimes
import std/times
import unittest

include carne/runtime

proc bench(name: string; code: string; iters: int) =
  ## Times hasAwaitToken over `iters` runs (after warmup) and prints
  ## total + per-iteration cost.
  var found = hasAwaitToken(code)
  let t0 = getMonoTime()
  for _ in 1 .. iters:
    found = hasAwaitToken(code)
  let ns = inNanoseconds(getMonoTime() - t0)
  echo name & ": found=" & $found &
    " bytes=" & $code.len &
    " iters=" & $iters &
    " per-iter=" & $(ns div iters) & "ns"

proc makeCode(lines: int; awaitMode: string): string =
  ## awaitMode: "none" | "start" | "end". Strings/comments contain the
  ## word await to exercise skipping (must not match).
  result = ""
  if awaitMode == "start":
    result.add("const x = await fetchData();\n")
  for i in 1 .. lines:
    result.add("// comment " & $i & " mentions await\n")
    result.add("const name" & $i & " = \"value await " & $i & "\";\n")
    result.add("const t" & $i & " = `tpl ${" & $i & " + 1} await`;\n")
    result.add("call" & $i & "(name" & $i & ", t" & $i & ");\n")
  if awaitMode == "end":
    result.add("const y = await finish();\n")

test "hasAwaitToken scan cost":
  bench("tiny-noawait ", "console.log(\"hi\");\n", 5_000)
  bench("tiny-await   ", "const v = await get();\n", 5_000)
  bench("awaited-ident",
    "const awaited = 1;\nconsole.log(awaited + 2);\n", 5_000)
  let medNone = makeCode(1_000, "none")
  let medStart = makeCode(1_000, "start")
  let medEnd = makeCode(1_000, "end")
  bench("med-none     ", medNone, 50)
  bench("med-start    ", medStart, 50)
  bench("med-end      ", medEnd, 50)
  let bigNone = makeCode(10_000, "none")
  let bigEnd = makeCode(10_000, "end")
  bench("big-none     ", bigNone, 10)
  bench("big-end      ", bigEnd, 10)
