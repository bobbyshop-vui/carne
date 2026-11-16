// hello — JS wrapper around the native addon.
// Build it first: ./native/build.sh.
//
// Scalar type checking lives at the native boundary (wrong types
// throw TypeError from Nim), so the wrapper only handles JS-side
// concerns: adapting shapes and composing new behavior.
const native = require("./native/hello.addon");

const { hello, add } = native;

function greetAll(names) {
  if (!Array.isArray(names)) {
    throw new TypeError("greetAll: names must be an array");
  }
  return names.map((name) => hello(name));
}

function shout(name) {
  return hello(name).toUpperCase() + "!";
}

module.exports = { hello, add, greetAll, shout };
