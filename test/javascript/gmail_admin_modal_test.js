// [unit] window.GmailAdmin.mailto (app/javascript/gmail_admin_modal.js): the
// "Email my admin" link's body breaks its lines with CRLF, as RFC 6068 asks of a
// mailto body (a bare LF is joined into one line by some mail clients). The
// module is run here, unchanged, against a stand-in window.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const SOURCE = readFileSync(new URL("../../app/javascript/gmail_admin_modal.js", import.meta.url), "utf8");

const gmailAdmin = () => {
  const window = {};
  vm.runInNewContext(SOURCE, { window, navigator: {}, setTimeout, clearTimeout, encodeURIComponent });
  return window.GmailAdmin;
};

const rawBodyOf = (href) => /[?&]body=([^&]*)/.exec(href)[1];

test("the mailto body breaks every line with CRLF and never a bare LF", () => {
  const href = gmailAdmin().mailto("123-abc.apps.googleusercontent.com");

  const raw = rawBodyOf(href);
  assert.match(raw, /%0D%0A/, "lines break with an encoded CRLF");
  assert.doesNotMatch(raw.replaceAll("%0D%0A", ""), /%0A|%0D/, "no bare LF or CR is left");
  const lines = decodeURIComponent(raw).split("\r\n");
  assert.equal(lines[0], "Hi,");
  assert.ok(lines.some((line) => line.endsWith("select McRitchie Studio: 123-abc.apps.googleusercontent.com")), "the client id rides step 3");
  assert.equal(lines.at(-1), "Thank you!");
});

test("with no client id the body still breaks with CRLF and asks the admin to search by name", () => {
  const href = gmailAdmin().mailto("");
  const lines = decodeURIComponent(rawBodyOf(href)).split("\r\n");
  assert.ok(lines.includes("3. Search for McRitchie Studio and select it"));
  assert.ok(href.startsWith("mailto:?subject="));
});
