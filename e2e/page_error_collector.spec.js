const { test, expect } = require("@playwright/test");
const { watchPageErrors } = require("./helpers");

// THE CONTRACT OF `watchPageErrors` ITSELF — the live-broadcast family's shared
// "the page stayed clean" watcher (e2e/helpers.js).
//
// WHY A SPEC FOR A TEST HELPER. That collector decides the verdict of ten specs,
// and on 2026-08-13 it decided one of them on CDN weather: three external 404s
// (a Montserrat woff2 from fonts.gstatic.com, and app.sprintful.com) landed in
// `pageErrors` and reddened a diff that touched no JS, no views and no e2e
// files. Re-running the same SHA went green. A collector that cannot tell an
// application error from third-party network noise is a coin flip wearing an
// assertion's clothes, so its scoping rule gets pinned like any other behavior.
//
// THE TWO DIRECTIONS, AND WHY THE SECOND IS THE POINT. Silencing the noise is
// easy and, alone, worse than the flake: a collector that ignores everything is
// green forever and guards nothing. So the pair below is deliberately
// SYMMETRIC — both tests 404 a subresource, both produce the byte-identical
// Chromium console text `Failed to load resource: the server responded with a
// status of 404 ()`, and the ONLY variable between them is the resource's
// ORIGIN. That isolation is the assertion: no text rule, no hostname rule and
// no "ignore 404s" rule can pass both, because at the level of message text the
// two cases are indistinguishable.
//
// NO REAL NETWORK. The third-party request is intercepted by `page.route` and
// fulfilled locally, so a spec about CDN flakiness never touches a CDN. It
// passes offline and its verdict does not depend on fonts.gstatic.com being up
// — which was the entire complaint.

// Chromium's console error for a failed subresource, verbatim and url-free.
// Asserted as a SHARED prefix in both directions to prove the two cases are
// textually identical and separable only by origin.
const RESOURCE_ERROR = "Failed to load resource";

// The real host from the incident, so the regression stays traceable to it.
const THIRD_PARTY_ORIGIN = "https://fonts.gstatic.com";
const THIRD_PARTY_RESOURCE = `${THIRD_PARTY_ORIGIN}/s/montserrat/v26/JTUSjIg1_i6t8kCHKm4536Wlhyw.woff2`;

// Append a subresource and resolve once the browser has finished with it,
// either way. `<img>` is used because a 404 body is never a decodable image, so
// the failure path is deterministic for any response the route hands back.
async function loadSubresource(page, src) {
  await page.evaluate(
    (url) =>
      new Promise((resolve) => {
        const img = document.createElement("img");
        img.addEventListener("load", resolve);
        img.addEventListener("error", resolve);
        img.src = url;
        document.body.appendChild(img);
      }),
    src
  );
}

// Wait for the console error the browser emits for `url`.
//
// THIS IS NOT A SLEEP, IT IS THE PROOF THE SCENARIO REPRODUCED. Without it both
// tests could pass vacuously — direction 1 by the third-party request never
// being made at all, which is exactly the "green for the wrong reason" this
// file exists to stop. It also removes a race: the collector's `console`
// listener is registered FIRST (Node dispatches listeners in registration
// order), so once this resolves the collector has already classified the
// message and the arrays below are settled.
function consoleErrorFor(page, url) {
  return page.waitForEvent("console", (msg) => msg.type() === "error" && msg.location().url === url);
}

// DIRECTION 1 — the flake itself. A third-party resource 404s and the spec
// PASSES, because a CDN's bad day is not an application error.
test("the page-error collector ignores a third-party resource failure", async ({ page }) => {
  const { pageErrors, failures, ignored, report } = watchPageErrors(page);

  await page.route(`${THIRD_PARTY_ORIGIN}/**`, (route) =>
    route.fulfill({ status: 404, contentType: "text/plain", body: "not found" })
  );

  await page.goto("/");

  const seen = consoleErrorFor(page, THIRD_PARTY_RESOURCE);
  await loadSubresource(page, THIRD_PARTY_RESOURCE);
  const message = await seen;

  // The scenario really happened, and it really is the url-free text that made
  // the original failure un-diagnosable from a CI log.
  expect(message.text()).toContain(RESOURCE_ERROR);
  expect(message.text()).not.toContain("gstatic");

  // The verdict every caller in this family asserts.
  expect(pageErrors, report()).toHaveLength(0);

  // Ignored, NOT invisible: still diagnosable from the report on both channels.
  expect(ignored.join("\n")).toContain(THIRD_PARTY_ORIGIN);
  expect(failures.join("\n")).toContain(THIRD_PARTY_RESOURCE);
  expect(report()).toContain("third-party origins");
});

// DIRECTION 2 — THE CONTROL, and the one that matters. Same event, same console
// text, application origin. If this ever passes while the collector is blind,
// the fix above has been converted into a permanent green light.
test("the page-error collector still catches an application error", async ({ page }) => {
  const { pageErrors, ignored, report } = watchPageErrors(page);

  await page.goto("/");

  // (a) THE SYMMETRIC CASE. A same-origin 404 — identical console text to
  //     direction 1, differing only in origin — must still count.
  const appResource = new URL("/e2e-missing-asset-does-not-exist.png", page.url()).toString();
  const seenResource = consoleErrorFor(page, appResource);
  await loadSubresource(page, appResource);
  const resourceMessage = await seenResource;

  expect(resourceMessage.text()).toContain(RESOURCE_ERROR);
  expect(pageErrors.join("\n"), report()).toContain(RESOURCE_ERROR);
  expect(ignored, report()).toHaveLength(0);

  // (b) THE UNCAUGHT EXCEPTION PATH, which the scoping rule deliberately does
  //     not touch. Asserted here so a future "scope pageerror too" edit cannot
  //     land silently.
  const marker = "e2e-control-application-error";
  const seenThrow = page.waitForEvent("pageerror", (err) => err.message.includes(marker));
  await page.evaluate((text) => {
    const script = document.createElement("script");
    script.textContent = `setTimeout(() => { throw new Error(${JSON.stringify(text)}); }, 0);`;
    document.body.appendChild(script);
  }, marker);
  await seenThrow;

  expect(pageErrors.join("\n"), report()).toContain(marker);
});
