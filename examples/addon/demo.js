const hello = require("./index.js");

console.log(hello.hello("ada"));
console.log(hello.add(40, 2));
console.log(JSON.stringify(hello.greetAll(["ada", "grace"])));
console.log(hello.shout("ada"));

try {
  hello.add("x", 2);
} catch (e) {
  console.log("caught " + e.constructor.name + ": " + e.message.split("\n")[0]);
}
