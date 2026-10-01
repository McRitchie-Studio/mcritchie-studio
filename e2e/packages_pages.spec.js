const { test, expect } = require("@playwright/test");

// /packages and /packages/stack (task tiered-packages-and-full-stack).
//
// WHY A BROWSER TIER EARNS ITS PLACE HERE. The integration tier proves the
// markup: four cards, each CTA's href, the matrix's rows. Only a browser proves
// what a visitor actually gets: that a paid tier's CTA opens the booking popup
// instead of leaving the page, that the two pages link both ways, and that on a
// phone the matrix scrolls sideways INSIDE its box while the page itself never
// does, with the tier header still in view after scrolling down the table.
//
// Google is stubbed: the spec is about the popup opening, and must not depend on
// whether a runner can reach calendar.google.com.

async function stubGoogle(page) {
  await page.route("https://calendar.google.com/**", (route) =>
    route.fulfill({ contentType: "text/html", body: "<p id='stub'>booking stub</p>" }));
}

test("a visitor compares the tiers, books a call from a paid card and reaches the full stack", async ({ page }) => {
  await stubGoogle(page);
  await page.goto("/packages");

  const cards = page.locator("[data-test='package-card']");
  await expect(cards).toHaveCount(4);
  await expect(cards.locator("h2")).toHaveText(["Vibe", "Pro", "Growth", "Enterprise"]);

  // Vibe builds; it never opens the popup.
  await expect(page.locator("[data-package='vibe'] [data-test='package-cta']")).toHaveAttribute("href", "/build");

  // The annual toggle swaps the monthly price for its discounted equivalent.
  const growth = page.locator("[data-test='package-card'][data-package='growth']");
  await expect(growth.locator("[data-test='price-monthly']")).toBeVisible();
  await page.locator("[data-test='billing-annual']").click();
  await expect(growth.locator("[data-test='price-annual']")).toContainText("$450");
  await expect(growth.locator("[data-test='price-monthly']")).toBeHidden();

  // Growth's CTA opens the booking dialog on this page, not /schedule.
  await growth.locator("[data-test='package-cta']").click();
  const dialog = page.locator("dialog[data-booking-dialog]");
  await expect(dialog).toBeVisible();
  await expect(page).toHaveURL(/\/packages$/);
  await expect(page.frameLocator("iframe[data-booking-popup-frame]").locator("#stub")).toHaveText("booking stub");
  await dialog.locator("[data-booking-close]").click();
  await expect(dialog).toBeHidden();

  // Enterprise's Book a call is live too: with no enterprise URL configured it
  // opens the same popup rather than a dead link.
  await page.locator("[data-package='enterprise'] [data-test='package-cta']").click();
  await expect(dialog).toBeVisible();
  await dialog.locator("[data-booking-close]").click();

  await page.locator("[data-test='full-stack-link']").click();
  await expect(page).toHaveURL(/\/packages\/stack$/);
  await expect(page.getByRole("heading", { name: "Everything in every tier" })).toBeVisible();
});

test("on a phone the full stack scrolls inside its box, keeps its tier header, and links back", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/packages/stack");

  const box = page.locator("[data-test='stack-matrix-scroll']");
  await expect(page.locator("[data-test='stack-row']").first()).toBeVisible();

  // The page never scrolls sideways; the matrix box does.
  const pageOverflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
  expect(pageOverflow).toBeLessThanOrEqual(0);
  const sideways = await box.evaluate((el) => el.scrollWidth - el.clientWidth);
  expect(sideways).toBeGreaterThan(0);

  // Scroll the box down a long way: the tier header row stays pinned to its top.
  await box.evaluate((el) => { el.scrollTop = 1200; });
  const header = page.locator("[data-test='stack-tier-header'][data-package='vibe']");
  const [boxTop, headerTop] = await Promise.all([
    box.evaluate((el) => el.getBoundingClientRect().top),
    header.evaluate((el) => el.getBoundingClientRect().top),
  ]);
  expect(Math.abs(headerTop - boxTop)).toBeLessThan(4);

  await page.locator("[data-test='back-to-packages']").click();
  await expect(page).toHaveURL(/\/packages$/);
  await expect(page.locator("[data-test='package-card']")).toHaveCount(4);
});
