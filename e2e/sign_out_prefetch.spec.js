// A pointer resting on Log out never signs the browser out (task
// build-funnel-held-message-cause): Turbo's 100ms hover prefetch of GET /logout
// once ran the sign-out. Since engine 0.141.1 (engine-logout-never-prefetched) the
// engine owns the fix: Log out carries data-turbo-prefetch="false", so Turbo never
// considers it, and Studio::ErrorHandling answers any prefetch that still arrives
// with 204. The hub keeps no copy (hub-adopts-engine-logout-guard); this proves
// the hub's own menu gets the engine's behaviour. The controls live in the engine's
// spec of the same name.
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
  // Turbo dispatches turbo:before-prefetch at mouseenter for a link it may
  // prefetch, and never for one that opts out.
  await page.evaluate(() => {
    window.__prefetchAsks = [];
    document.addEventListener("turbo:before-prefetch", (event) => {
      window.__prefetchAsks.push(event.target.getAttribute("href"));
    });
  });

  await page.getByRole("button", { name: "Alex", exact: true }).click();
  const logOut = page.locator("#studio-link-sidebar-mobile a[href='/logout']");
  await expect(logOut).toBeVisible();
  await expect(logOut, "the engine's Log out opts out of prefetch").toHaveAttribute("data-turbo-prefetch", "false");
  await logOut.hover();

  // An absent request has no event to wait for: rest five times Turbo's 100ms delay.
  const asked = await page
    .waitForRequest((request) => new URL(request.url()).pathname === "/logout", { timeout: 500 })
    .then(() => true, () => false);
  expect(asked, "a 500ms rest on Log out asks /logout nothing").toBe(false);
  expect(await page.evaluate(() => window.__prefetchAsks), "Turbo never considers Log out").not.toContain("/logout");
  expect(signOuts, "no request reached /logout").toEqual([]);

  await page.goto("/build");
  await expect(page.getByRole("button", { name: "Toggle admin menu" }), "still signed in as the admin").toBeVisible();
});
