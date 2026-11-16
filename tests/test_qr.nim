import unittest

import carne
import carne/modules
import carne/std/qr

registerStd("std/qr", qr.install)

test "qr encode size and svg":
  check runCode(
    "require('std/qr').encode('hello').size") == "21"
  check runCode(
    "require('std/qr').encode('hello').svg.slice(0, 5)") == "<svg "
  check runCode(
    "require('std/qr').encode('hello', {ecLevel: 'H'}).size") == "21"
  check runCode(
    "require('std/qr').encode('hello').terminal.length > 0") == "true"

test "qr encode rejects bad ecLevel":
  expect CarneError:
    discard runCode("require('std/qr').encode('hi', {ecLevel: 'Z'})")
  expect CarneError:
    discard runCode("require('std/qr').encode('hi', 42)")

test "qr encode rejects overflow":
  expect CarneError:
    discard runCode("require('std/qr').encode('x'.repeat(5000))")

test "qr encode all families":
  check runCode(
    "require('std/qr').encode('hello', {family: 'model1'}).family") == "model1"
  check runCode(
    "require('std/qr').encode('hello', {family: 'model1'}).version") == "1"
  check runCode(
    "require('std/qr').encode('HI', {family: 'micro'}).family") == "micro"
  check runCode(
    "require('std/qr').encode('HI', {family: 'micro'}).version") == "M2"
  check runCode(
    "require('std/qr').encode('1', {family: 'micro', ecLevel: 'L'}).version") == "M1"
  check runCode(
    "require('std/qr').encode('1', {family: 'micro', ecLevel: 'L'}).size") == "11"
  check runCode(
    "require('std/qr').encode('hello', {family: 'rmqr'}).family") == "rmqr"
  check runCode(
    "require('std/qr').encode('hello', {family: 'rmqr'}).width > 0") == "true"
  check runCode(
    "require('std/qr').encode('A', {family: 'micro', version: 'M2'}).size") == "13"
  check runCode(
    "require('std/qr').encode('hello', {version: 2}).size") == "25"
  check runCode(
    "require('std/qr').encode('hello').width") == "21"
  check runCode(
    "require('std/qr').encode('hello').height") == "21"
  check runCode(
    "require('std/qr').encode('hello').modules.length") == "21"

test "qr encode rejects bad family options":
  expect CarneError:
    discard runCode("require('std/qr').encode('hi', {family: 'qr9'})")
  expect CarneError:
    discard runCode(
      "require('std/qr').encode('hi', {family: 'micro', ecLevel: 'H'})")
  expect CarneError:
    discard runCode(
      "require('std/qr').encode('hi', {family: 'rmqr', ecLevel: 'L'})")
  expect CarneError:
    discard runCode("require('std/qr').encode('hi', {mask: 9})")
  expect CarneError:
    discard runCode(
      "require('std/qr').encode('hi', {family: 'rmqr', mask: 1})")
  expect CarneError:
    discard runCode(
      "require('std/qr').encode('hi', {family: 'micro', eci: 26})")
  expect CarneError:
    discard runCode(
      "require('std/qr').encode('hi', {family: 'model1', version: 13})")
  expect CarneError:
    discard runCode("require('std/qr').encode('hi', {version: 41})")
  expect CarneError:
    discard runCode(
      "require('std/qr').encode('hi', {family: 'micro', version: 'M9'})")

test "qr decode roundtrips every family":
  check runCode(
    "const qr = require('std/qr');" &
    "qr.decode(qr.encode('hello model2').modules).text") == "hello model2"
  check runCode(
    "const qr = require('std/qr');" &
    "qr.decode(qr.encode('hello m1', {family: 'model1'}).modules).family") == "model1"
  check runCode(
    "const qr = require('std/qr');" &
    "qr.decode(qr.encode('HI9', {family: 'micro'}).modules).version") == "M2"
  check runCode(
    "const qr = require('std/qr');" &
    "qr.decode(qr.encode('hello rmqr', {family: 'rmqr'}).modules).text") == "hello rmqr"
  check runCode(
    "const qr = require('std/qr');" &
    "const a = qr.encodeAqr('core here', 'ring here');" &
    "const d = qr.decode(a.modules);" &
    "d.text + '|' + d.ring + '|' + d.family") == "core here|ring here|aqr"

test "qr decode rejects garbage":
  expect CarneError:
    discard runCode("require('std/qr').decode([[0, 1], [1, 0]])")
  expect CarneError:
    discard runCode("require('std/qr').decode([[1, 0], [1]])")
  expect CarneError:
    discard runCode("require('std/qr').decode([[2]])")
  expect CarneError:
    discard runCode(
      "const qr = require('std/qr');" &
      "qr.decode(qr.encode('hi').modules, {family: 'micro'})")

test "qr payload builders":
  check runCode(
    "require('std/qr').wifi('cafe')") == "WIFI:T:nopass;S:cafe;;"
  check runCode(
    "require('std/qr').wifi('cafe', {password: 'secret'})") == "WIFI:T:WPA;S:cafe;P:secret;;"
  check runCode(
    "require('std/qr').url('example.com/menu')") == "https://example.com/menu"
  check runCode(
    "require('std/qr').url('https://a.example/x')") == "https://a.example/x"
  check runCode(
    "require('std/qr').sms('+1000', 'hi')") == "SMSTO:+1000:hi"
  check runCode(
    "require('std/qr').email('a@b.c', {subject: 's'})") == "mailto:a@b.c?subject=s"
  check runCode(
    "require('std/qr').mecard('Ada L.', {phone: '+1'})") == "MECARD:N:Ada L.;TEL:+1;;"

test "qr sqrc seals and opens":
  check runCode(
    "const qr = require('std/qr');" &
    "const s = qr.sqrc('visible', 'gem', '0123456789abcdef');" &
    "const o = qr.unsqrc(qr.decode(s.modules).text, '0123456789abcdef');" &
    "o.ok + '|' + o.publicText + '|' + o.privateText") == "true|visible|gem"
  check runCode(
    "const qr = require('std/qr');" &
    "const s = qr.sqrc('visible', 'gem', '0123456789abcdef');" &
    "qr.unsqrc(qr.decode(s.modules).text, 'fedcba9876543210').ok") == "false"
  check runCode(
    "require('std/qr').sqrc('v', 'g', '0123456789abcdef').family") == "sqrc"
