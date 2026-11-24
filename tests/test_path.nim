import unittest

import carne
import carne/modules
import carne/std/path

registerStd("std/path", path.install)

test "path parse local file":
  check runCode(
    "JSON.stringify(require('std/path').parse('/a/b/c.txt'))") ==
    """{"kind":"local","absolute":true,"segments":["a","b","c.txt"],""" &
    """"ext":"txt"}"""

test "path parse url with auth, port, query and fragment":
  check runCode(
    "JSON.stringify(require('std/path').parse(" &
    "'https://user@host:8080/p?q=1#frag'))") ==
    """{"kind":"web","scheme":"https","user":"user","host":"host",""" &
    """"port":8080,"path":"/p","segments":["p"],""" &
    """"query":[{"key":"q","value":"1"}],"fragment":"frag"}"""

test "path parse relative has no ext key":
  check runCode(
    "JSON.stringify(require('std/path').parse('a/b'))") ==
    """{"kind":"local","absolute":false,"segments":["a","b"]}"""

test "path format roundtrips parse":
  check runCode(
    "const p = require('std/path');" &
    "p.format(p.parse('/a/b/c.txt'))") == "/a/b/c.txt"
  check runCode(
    "const p = require('std/path');" &
    "p.format(p.parse('https://user@host:8080/p?q=1#frag'))") ==
    "https://user@host:8080/p?q=1#frag"
  check runCode(
    "const p = require('std/path');" &
    "p.format(p.parse('a/b'))") == "a/b"
  check runCode(
    "const p = require('std/path');" &
    "p.format(p.parse('mailto:hello@example.com'))") ==
    "mailto:hello@example.com"

test "path join and normalize":
  check runCode(
    "require('std/path').join(['a', 'b', 'c.txt'])") == "a/b/c.txt"
  check runCode(
    "require('std/path').join(['a', './b', '../c'])") == "a/c"
  check runCode("require('std/path').normalize('a/./b/../c')") == "a/c"
  check runCode("require('std/path').normalize('/a//b/./c/../d')") ==
    "/a/b/d"
  check runCode(
    "require('std/path').normalize('https://host/a/./b/../c?q=1')") ==
    "https://host/a/c?q=1"

test "path format and join validate input":
  expect CarneError:
    discard runCode("require('std/path').format({kind: 'bogus'})")
  expect CarneError:
    discard runCode("require('std/path').format({})")
  expect CarneError:
    discard runCode("require('std/path').join('not-array')")
  expect CarneError:
    discard runCode("require('std/path').join([1, 2])")
