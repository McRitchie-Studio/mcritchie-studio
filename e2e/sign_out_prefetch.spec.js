// A pointer resting on Log out never signs the browser out (task
// build-funnel-held-message-cause). The engine's Log out is a GET to /logout, and
// Turbo prefetches a link the pointer rests on for 100ms: that prefetch ran the
// sign-out, and its Set-Cookie dropped the session while the page still drew the
// user. In build_funnel.spec.js the cursor left on the claim button rested on the
// menu's Log out, so the admin's next /build message went in signed out and the
// bot shield held it. app/javascript/sign_out_prefetch.js cancels the prefetch;
// ApplicationController#refuse_prefetched_sign_out answers any that still arrives.
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink, VISITOR } = require("./helpers");

test.use({ storageState: VISITOR });

test("hovering Log out in the menu asks the server nothing and keeps the session", async ({ page }) => {
  await page.setViewportSize({ width: 360, height: 780 });
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/build");

  const signOuts = [];
  page.on("request", (request) => {
    if (new URL(request.url()).pathname === "/logout") signOuts.push(request.headers()["x-sec-purpose"] || "visit");
  });
  // Turbo dispatches turbo:before-prefetch on the link as the pointer enters it.
  // Recorded after the app's own listener has run, so `prevented` is its verdict.
  await page.evaluate(() => {
    window.__prefetchAsks = [];
    document.addEventListener("turbo:before-prefetch", (event) => {
      window.__prefetchAsks.push({ href: event.target.getAttribute("href"), prevented: event.defaultPrevented });
    });
  });

  await page.getByRole("button", { name: "Alex", exact: true }).click();
  const logOut = page.locator("#studio-link-sidebar-mobile a[href='/logout']");
  await expect(logOut).toBeVisible();
  await logOut.hover();

  await expect.poll(() => page.evaluate(() => window.__prefetchAsks), { message: "Turbo asked about prefetching Log out" })
    .toContainEqual({ href: "/logout", prevented: true });
  expect(signOuts, "no request reached /logout").toEqual([]);

  await page.goto("/build");
  await expect(page.getByRole("button", { name: "Toggle admin menu" }), "still signed in as the admin").toBeVisible();
});
