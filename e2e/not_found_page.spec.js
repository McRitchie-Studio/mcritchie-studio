// [e2e] The friendly not-found page (task friendly-not-found-page). Alex McRitchie,
// 2026-11-07: "When users get lost they have a friendly page to land on and link back
// to the root app they are working on."
//
// A signed-out visitor types an address the hub does not have. The answer is a 404,
// the page names the hub and offers one button home, and the button lands on /.
// The e2e server runs with ENABLE_ERROR_PAGES=1 (playwright.config.js), so it shows
// what a visitor sees, not the test environment's debug report.
//
// On an engine that has Studio::ExceptionsApp this is the engine's page inside the
// hub's layout; until the release relocks one, it is public/404.html. Both carry the
// same words and the same data-test hooks, so this reads whichever engine is locked.
const { test, expect } = require("@playwright/test");
const { watchPageErrors, VISITOR } = require("./helpers");

test.use({ storageState: VISITOR });

test("a lost visitor sees the friendly not-found page, and its home button lands on /", async ({ page }) => {
  const { pageErrors, failures, report } = watchPageErrors(page);

  const response = await page.goto("/no-such-page");
  expect(response.status(), "a lost address answers 404, never a 200 or a redirect").toBe(404);
  expect(response.request().redirectedFrom(), "no redirect on the way").toBeNull();
  await expect(page).toHaveURL(/\/no-such-page$/);

  const lost = page.locator("[data-test='not-found']");
  await expect(lost).toBeVisible();
  await expect(lost.getByRole("heading", { level: 1 })).toHaveText("This page isn’t here");
  await expect(page).toHaveTitle("Page not found · McRitchie Studio");

  const home = lost.locator("a[data-test='not-found-home']");
  await expect(home).toHaveText("Back to McRitchie Studio");
  await expect(home).toHaveAttribute("href", "/");

  await home.click();
  await expect(page).toHaveURL(/\/$/);
  await expect(page.locator("[data-test='not-found']")).toHaveCount(0);

  // The lost address itself is the one failing request, and Chromium logs one
  // console line for it. Anything else (a missing logo, a script error) fails here.
  const lostAddress = failures.filter((line) => /^404 GET \S+\/no-such-page$/.test(line));
  expect(lostAddress, report()).toHaveLength(1);
  expect(failures.filter((line) => !lostAddress.includes(line)), report()).toEqual([]);
  expect(pageErrors.filter((text) => !/status of 404 \(Not Found\)$/.test(text)), report()).toEqual([]);
  expect(pageErrors.length, report()).toBeLessThanOrEqual(1);
});
