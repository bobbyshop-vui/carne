import std/os
import unittest

import carne/cli

test "build version matches carne.nimble":
  ## versionStr is parsed from carne.nimble at compile time; this
  ## re-parses the working-tree file so format drift fails loudly.
  if not fileExists("carne.nimble"):
    skip()
  check versionStr == nimbleVersionStr(readFile("carne.nimble"))
  check versionStr.len > 0

test "confirm declines without a tty":
  ## Test runners pipe stdin, so this deterministically takes the
  ## non-interactive path (never blocks, never confirms).
  check confirm("Remove foo?") == false

test "spinner stays idle without a tty":
  ## Test runners pipe stdout: no thread starts, stop is a no-op.
  check spinnerActive() == false
  var s = startSpinner("Installing packages...")
  check s.running == false
  check spinnerActive() == false
  stopSpinner(s)
  check spinnerActive() == false

test "withSpinner runs the body without a tty":
  var ran = false
  withSpinner("Installing packages..."):
    ran = true
  check ran == true
  check spinnerActive() == false

test "withSpinner propagates exceptions after stopping":
  expect CatchableError:
    withSpinner("Installing packages..."):
      raise newException(CatchableError, "boom")
  check spinnerActive() == false

test "splitScriptArgs passes the run tail through verbatim":
  check splitScriptArgs(@["run", "app.js", "--name", "ada",
    "-v"]) == (@["run", "app.js"], @["--name", "ada", "-v"])
  check splitScriptArgs(@["--isatty:false", "run", "app.js",
    "--x=1"]) == (@["--isatty:false", "run", "app.js"], @["--x=1"])
  check splitScriptArgs(@["run", "app.js"]) == (@["run", "app.js"], @[])
  check splitScriptArgs(@["run"]) == (@["run"], @[])
  check splitScriptArgs(@["run", "--help"]) ==
    (@["run", "--help"], @[])

test "splitScriptArgs leaves other commands alone":
  check splitScriptArgs(@["pkg", "install", "foo"]) ==
    (@["pkg", "install", "foo"], @[])
  check splitScriptArgs(@["bump", "--level", "major"]) ==
    (@["bump", "--level", "major"], @[])
  check splitScriptArgs(@["--help"]) == (@["--help"], @[])

test "splitScriptArgs splits bare script paths, not commands":
  let dir = getTempDir() / "carne_cli_split"
  createDir(dir)
  let app = dir / "app.js"
  writeFile(app, "console.log(1)")
  check splitScriptArgs(@[app, "--flag", "x"]) ==
    (@[app], @["--flag", "x"])
  check splitScriptArgs(@[app]) == (@[app], @[])
  check splitScriptArgs(@["test", app]) == (@["test", app], @[])
  removeDir(dir)
