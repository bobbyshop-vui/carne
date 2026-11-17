const terminal = require("std/terminal");

// CLI demo: `carne run examples/terminal.js [greet|info|ask] [--name ada] [-v]`
// Everything after the script path reaches the script verbatim, so
// script flags never clash with carne's own (those go before `run`).
const args = terminal.parseArgs(undefined, {
  boolean: ["verbose", "help"],
  string: ["name"],
  alias: { v: "verbose", h: "help", n: "name" },
  default: { name: "world", verbose: false },
  positional: ["cmd"]
});

if (args.help) {
  console.log("usage: carne run examples/terminal.js [greet|info|ask] [--name ada] [-v]");
  console.log("  greet --name ada    styled greeting (default cmd)");
  console.log("  info                tty, colors, size");
  console.log("  ask                 interactive readLine + readPassword");
}

const cmd = args.cmd || "greet";

if (cmd === "greet") {
  console.log(terminal.bold(terminal.green("hello, " + args.name)));
  if (args.verbose) {
    console.log("plain: " + terminal.stripAnsi(
      terminal.bold(terminal.green("hello, " + args.name))));
    console.log("colorEnabled: " + terminal.colorEnabled());
  }
} else if (cmd === "info") {
  console.log("isTTY: " + terminal.isTTY());
  console.log("colorEnabled: " + terminal.colorEnabled());
  console.log("size: " + terminal.columns() + "x" + terminal.rows());
  terminal.write("raw write, no newline..." + "\n");
  console.log(terminal.dim("dim") + " " + terminal.underline("underline"));
} else if (cmd === "ask") {
  const who = terminal.readLine("name: ");
  if (who === null) {
    console.log("no input (EOF)");
  } else {
    const pw = terminal.readPassword("password: ");
    console.log("hi " + who + " (password length " +
      (pw === null ? "n/a" : String(pw.length)) + ")");
  }
} else {
  console.log("unknown cmd: " + cmd);
}
