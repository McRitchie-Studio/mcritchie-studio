// [unit] app/javascript/sign_out_prefetch.js: Turbo's hover prefetch is cancelled
// for a sign-out link (GET /logout) and left alone for every other link, so a
// pointer resting on Log out never signs the browser out (task
// build-funnel-held-message-cause).
import { test } from "node:test";
import assert from "node:assert/strict";
import { isSignOutLink, refuseSignOutPrefetch, SIGN_OUT_PATHS } from "../../app/javascript/sign_out_prefetch.js";

const ORIGIN = "http://127.0.0.1:3000";
const link = (href) => ({ getAttribute: (name) => (name === "href" ? href : null) });
const event = (href) => {
  const seen = { prevented: false };
  return { target: link(href), preventDefault() { seen.prevented = true; }, seen };
};

test("the engine's sign-out path is the one listed", () => {
  assert.deepEqual(SIGN_OUT_PATHS, [ "/logout" ]);
});

test("a link to /logout, relative or absolute, with a trailing slash or a query, is a sign-out", () => {
  for (const href of [ "/logout", "/logout/", "/logout?return_to=/build", `${ORIGIN}/logout` ]) {
    assert.equal(isSignOutLink(link(href), ORIGIN), true, href);
  }
});

test("other links, another origin's /logout, and a link with no href are not", () => {
  for (const href of [ "/build", "/login", "/logout-help", "/admin/logout", "https://example.com/logout", "#logout" ]) {
    assert.equal(isSignOutLink(link(href), ORIGIN), false, href);
  }
  assert.equal(isSignOutLink(link(null), ORIGIN), false);
  assert.equal(isSignOutLink(null, ORIGIN), false);
});

test("the listener cancels the prefetch of a sign-out and only that", () => {
  const signOut = event("/logout");
  refuseSignOutPrefetch(signOut, ORIGIN);
  assert.equal(signOut.seen.prevented, true);

  const page = event("/build");
  refuseSignOutPrefetch(page, ORIGIN);
  assert.equal(page.seen.prevented, false);
});
