const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

// /contacts — the mailing list, watched live (task contacts-admin-page).
//
// WHY A BROWSER TIER EARNS ITS PLACE HERE. The component tier proves the tiles and
// the table render their counts. Only a browser proves the two things this page
// adds in script: the stats frame RELOADS on a 10s poll that stops while the tab is
// hidden, and a row EXPANDS into its lazy detail frame. It also measures the page
// at a phone width, where a wide table must scroll inside its card, not the page.
//
// The six cyvasse-legacy contacts come from e2e/seed.rb. NOT @qa-readonly: those
// rows do not exist in production.

const isStats = (req) => new URL(req.url()).pathname === "/contacts/stats";

test("tiles show the list, the stats poll every 10s only while visible, and a row expands", async ({ page }) => {
  await page.clock.install();
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/contacts");

  await expect(page.getByRole("heading", { name: "Contacts", level: 1 })).toBeVisible();
  const tile = (key) => page.locator(`[data-stat=${key}] [data-stat-count]`);
  await expect(tile("total")).toHaveText("6");
  await expect(tile("mailable")).toHaveText("1");
  await expect(tile("undeliverable")).toHaveText("1");
  await expect(tile("unverified")).toHaveText("2");
  await expect(tile("emailed")).toHaveText("1");
  await expect(page.locator("[data-status-count=catch-all]")).toHaveText("1");

  // THE POLL: one tick reloads the stats frame from /contacts/stats.
  const first = page.waitForRequest(isStats);
  await page.clock.runFor(10_000);
  expect(new URL((await first).url()).searchParams.get("list")).toBe("cyvasse-legacy");
  await expect(tile("total")).toHaveText("6");

  // HIDDEN: ticks pass and nothing is fetched.
  let hiddenFetches = 0;
  const counter = (req) => { if (isStats(req)) hiddenFetches += 1; };
  await page.evaluate(() => {
    Object.defineProperty(document, "hidden", { configurable: true, get: () => true });
    document.dispatchEvent(new Event("visibilitychange"));
  });
  page.on("request", counter);
  await page.clock.runFor(30_000);
  page.off("request", counter);
  expect(hiddenFetches).toBe(0);

  // SHOWN AGAIN: it refreshes at once, without waiting for the next tick.
  const back = page.waitForRequest(isStats);
  await page.evaluate(() => {
    Object.defineProperty(document, "hidden", { configurable: true, get: () => false });
    document.dispatchEvent(new Event("visibilitychange"));
  });
  await back;

  // A row expands into its sends and events.
  const row = page.locator("[data-contact-row]", { hasText: "valid@example.com" }).first();
  await row.getByRole("button", { name: /valid@example.com/ }).click();
  await expect(row.locator("[data-contact-detail]")).toContainText("Cyvasse is back");
  await expect(row.locator("[data-contact-detail]")).toContainText("Clicked");
});

test("the filters narrow the table", async ({ page }) => {
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/contacts");
  await page.locator("select[name=status]").selectOption("unverified");
  await page.getByRole("button", { name: "Filter" }).click();
  await expect(page).toHaveURL(/status=unverified/);
  await expect(page.locator("[data-contact-row]")).toHaveCount(2);
  await expect(page.locator("[data-stat=total] [data-stat-count]")).toHaveText("6");
});

test("at 375px the page itself never scrolls sideways", async ({ page }) => {
  await page.setViewportSize({ width: 375, height: 812 });
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/contacts");
  await expect(page.locator("[data-stat=total]")).toBeVisible();
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
  expect(overflow).toBeLessThanOrEqual(0);
});
