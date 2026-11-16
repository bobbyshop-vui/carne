const qr = require("std/qr");
const os = require("std/os");

// Terminal rendering for humans, SVG for everything else.
const q = qr.encode("https://example.com/menu");
console.log("size: " + q.size + "x" + q.size);
console.log(q.terminal);
os.writeFile("/tmp/carne_demo_qr.svg", q.svg);
console.log("svg bytes: " + os.readFile("/tmp/carne_demo_qr.svg").length);
os.remove("/tmp/carne_demo_qr.svg");

// Higher correction survives scrambled printouts.
for (const level of ["L", "H"])
  console.log(level + ": version size " +
    qr.encode("backup code 7", {ecLevel: level}).size);

// Every family, decoded straight back from its own modules.
for (const family of ["model2", "model1", "micro", "rmqr"]) {
  const code = qr.encode("hello " + family, {family: family});
  const back = qr.decode(code.modules);
  console.log(family + ": " + code.width + "x" + code.height +
    " v" + code.version + " -> " + back.text);
}

// Pinning the version and the decoder both work when you need them.
const pinned = qr.encode("HI", {family: "micro", version: "M2"});
console.log("pinned: " + pinned.version + " " + pinned.size + "x" + pinned.size);
console.log("pinned decode: " +
  qr.decode(pinned.modules, {family: "micro"}).text);

// An AQR symbol carries a Model 2 core plus a data ring.
const aqr = qr.encodeAqr("core payload", "ring-data");
const scanned = qr.decode(aqr.modules);
console.log("aqr: " + scanned.text + " + ring " + scanned.ring);

// Payload builders feed straight into encode.
console.log(qr.wifi("cafe", {password: "secret"}));
console.log(qr.url("example.com/menu"));
console.log(qr.mecard("Ada L.", {phone: "+1000", email: "ada@example.com"}));
console.log(qr.sms("+1000", "running late"));
console.log(qr.email("ops@example.com", {subject: "deploy", body: "v0.1.6 out"}));
const vcard = require("std/vcard").stringify([{
  fn: "Ada Lovelace",
  emails: [{value: "ada@example.com"}]
}]);
console.log(qr.decode(qr.encode(vcard).modules).text.split("\n")[0]);

// SQRC seals a private area that only the key reopens.
const key = "0123456789abcdef";
const sealed = qr.sqrc("visible", "hidden-gem", key);
const opened = qr.unsqrc(qr.decode(sealed.modules).text, key);
console.log("sqrc: " + opened.publicText + " / " + opened.privateText);
