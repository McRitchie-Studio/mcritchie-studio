// [unit] window.copyText (app/views/components/_copy_text_script.html.erb) answers
// whether the text reached the clipboard, so a caller can say "Copied" only when
// it did. The partial's own <script> body is run here, unchanged, against a
// stand-in window, document and navigator: nothing is copied from it by hand.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const PARTIAL = new URL("../../app/views/components/_copy_text_script.html.erb", import.meta.url);
const SCRIPT = /<script>([\s\S]*?)<\/script>/.exec(readFileSync(PARTIAL, "utf8"))[1];

// A page with the partial rendered. `clipboard`: "resolves", "rejects" or "absent"
// (an insecure context). `exec`: what document.execCommand("copy") returns, or
// "throws". Returns the window, with what was written and what was left in the body.
const page = ({ clipboard, exec }) => {
  const seen = { api: [], exec: [], inBody: 0, warned: 0 };
  const document = {
    createElement: () => ({ style: {}, setAttribute() {}, select() {}, value: "" }),
    body: {
      appendChild(el) { seen.inBody += 1; seen.pending = el; },
      removeChild() { seen.inBody -= 1; },
    },
    execCommand(command) {
      seen.exec.push([command, seen.pending.value]);
      if (exec === "throws") throw new Error("execCommand is not allowed here");
      return exec;
    },
  };
  const navigator = {};
  if (clipboard !== "absent") {
    navigator.clipboard = {
      writeText(text) {
        seen.api.push(text);
        return clipboard === "resolves" ? Promise.resolve() : Promise.reject(new Error("NotAllowedError"));
      },
    };
  }
  const window = {};
  vm.runInNewContext(SCRIPT, { window, document, navigator, console: { warn() { seen.warned += 1; } }, String, Promise });
  return { window, seen };
};

test("the clipboard API refuses and execCommand answers false: copyText answers false", async () => {
  const { window, seen } = page({ clipboard: "rejects", exec: false });

  assert.equal(await window.copyText("a caption"), false);
  assert.deepEqual(seen.api, ["a caption"]);
  assert.deepEqual(seen.exec, [["copy", "a caption"]], "the fallback was tried, with the same text");
  assert.equal(seen.inBody, 0, "the hidden textarea is taken out again");
});

test("the positive control: the clipboard API refuses and execCommand copies, so copyText answers true", async () => {
  const { window, seen } = page({ clipboard: "rejects", exec: true });

  assert.equal(await window.copyText("a caption"), true);
  assert.deepEqual(seen.exec, [["copy", "a caption"]]);
});

test("no clipboard API (an insecure context): the answer is execCommand's, true or false", () => {
  assert.equal(page({ clipboard: "absent", exec: true }).window.copyText("x"), true);
  assert.equal(page({ clipboard: "absent", exec: false }).window.copyText("x"), false);
});

test("an execCommand that throws is a false, and the page is told nothing was copied", async () => {
  const { window, seen } = page({ clipboard: "rejects", exec: "throws" });

  assert.equal(await window.copyText("x"), false);
  assert.equal(seen.warned, 1);
});

test("the clipboard API takes the text: execCommand is never asked, and the answer is not false", async () => {
  const { window, seen } = page({ clipboard: "resolves", exec: false });

  // writeText resolves undefined; every caller reads `=== false` as "not copied".
  assert.notEqual(await window.copyText("x"), false);
  assert.deepEqual(seen.exec, []);
});

test("null and numbers are copied as text", async () => {
  const { window, seen } = page({ clipboard: "resolves", exec: true });

  await window.copyText(null);
  await window.copyText(42);
  assert.deepEqual(seen.api, ["", "42"]);
});
