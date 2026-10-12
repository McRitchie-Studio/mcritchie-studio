const { test, expect } = require("@playwright/test");
const { VISITOR } = require("./helpers");

// What a visitor sees: signed out, not the suite's default admin session.
test.use({ storageState: VISITOR });

// /packages and /packages/stack (task tiered-packages-and-full-stack; the
// 2026-10-12 ladder from task cto-and-team-tiers: Vibe, Pro, CTO and Team cards,
// Enterprise as a Talk to us line under them).
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
  await expect(cards.locator("h2")).toHaveText(["Vibe", "Pro", "CTO", "Team"]);
  await expect(page.locator("[data-test='package-card'][data-package='team'] [data-test='price-monthly']")).toContainText("$1,500");

  // Each card names its brands in full-color logos that actually load.
  const vibeLogos = page.locator("[data-package='vibe'] [data-test='package-powered-by'] [data-test='brand-logo']");
  await expect(vibeLogos).toHaveCount(3);
  await expect(vibeLogos.first()).toHaveAttribute("aria-label", "GitHub");
  const loaded = await page.locator("[data-test='package-powered-by'] img").evaluateAll((imgs) =>
    imgs.map((img) => img.complete && img.naturalWidth > 0));
  expect(loaded.length).toBeGreaterThan(10);
  expect(loaded.every(Boolean)).toBe(true);

  // Vibe builds; it never opens the popup.
  await expect(page.locator("[data-package='vibe'] [data-test='package-cta']")).toHaveAttribute("href", "/build");

  // The annual toggle swaps the monthly price for its discounted equivalent.
  const cto = page.locator("[data-test='package-card'][data-package='cto']");
  await expect(cto.locator("[data-test='price-monthly']")).toBeVisible();
  await page.locator("[data-test='billing-annual']").click();
  await expect(cto.locator("[data-test='price-annual']")).toContainText("$450");
  await expect(cto.locator("[data-test='price-monthly']")).toBeHidden();

  // CTO's CTA opens the booking dialog on this page, not /schedule.
  await cto.locator("[data-test='package-cta']").click();
  const dialog = page.locator("dialog[data-booking-dialog]");
  await expect(dialog).toBeVisible();
  await expect(page).toHaveURL(/\/packages$/);
  await expect(page.frameLocator("iframe[data-booking-popup-frame]").locator("#stub")).toHaveText("booking stub");
  await dialog.locator("[data-booking-close]").click();
  await expect(dialog).toBeHidden();

  // Enterprise is no card: a Talk to us line under the cards. Its Book a call is
  // live: with no enterprise URL configured it opens the same booking popup
  // rather than a dead link.
  const talk = page.locator("[data-test='talk-to-us'][data-package='enterprise']");
  await expect(talk).toContainText("Need more apps, white label or custom connectors? Talk to us");
  const book = talk.getByRole("link", { name: "Book a call" });
  await book.scrollIntoViewIfNeeded();
  await book.click();
  await expect(dialog).toBeVisible();
  await expect(page).toHaveURL(/\/packages$/);
  await expect(page.frameLocator("iframe[data-booking-popup-frame]").locator("#stub")).toHaveText("booking stub");
  await dialog.locator("[data-booking-close]").click();

  await page.locator("[data-test='full-stack-link']").click();
  await expect(page).toHaveURL(/\/packages\/stack$/);
  await expect(page.getByRole("heading", { name: "Everything in every tier" })).toBeVisible();

  // The full stack keeps the Enterprise column and the same Talk to us line.
  await expect(page.locator("[data-test='stack-tier-header']")).toHaveCount(5);
  const stackTalk = page.locator("[data-test='talk-to-us'][data-package='enterprise']");
  await stackTalk.scrollIntoViewIfNeeded();
  await stackTalk.getByRole("link", { name: "Book a call" }).click();
  await expect(dialog).toBeVisible();
  await expect(page).toHaveURL(/\/packages\/stack$/);
  await dialog.locator("[data-booking-close]").click();
});

test("on a phone the full stack scrolls inside its box, keeps its tier header, and links back", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/packages/stack");

  const box = page.locator("[data-test='stack-matrix-scroll']");
  await expect(page.locator("[data-test='stack-row']").first()).toBeVisible();

  // The narrow feature column leaves two tiers in view, row descriptions hide,
  // and a one-brand row leads with that brand's logo.
  const boxRight = await box.evaluate((el) => el.getBoundingClientRect().right);
  const proRight = await page.locator("[data-test='stack-tier-header'][data-package='pro']")
    .evaluate((el) => el.getBoundingClientRect().right);
  expect(proRight).toBeLessThanOrEqual(boxRight);
  await expect(page.locator("[data-test='stack-blurb']").first()).toBeHidden();
  const serverLogo = page.locator("[data-feature='server'] [data-test='stack-lead'] [data-brand='heroku'] img");
  await expect(serverLogo).toBeVisible();
  expect(await serverLogo.evaluate((img) => img.naturalWidth)).toBeGreaterThan(0);

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

  // The Talk to us line stacks on a phone without pushing the page sideways.
  const talkCta = page.locator("[data-test='talk-to-us'] [data-test='package-cta']");
  await talkCta.scrollIntoViewIfNeeded();
  await expect(talkCta).toBeVisible();
  const packagesOverflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
  expect(packagesOverflow).toBeLessThanOrEqual(0);
});

test("CTO and Team show Cloudflare DNS, and the full stack draws it in action on a phone", async ({ page }) => {
  await page.goto("/packages");

  for (const key of ["cto", "team"]) {
    const spot = page.locator(`[data-test='package-card'][data-package='${key}'] [data-test='package-spotlight'][data-feature='cloudflare-dns']`);
    await expect(spot).toContainText("Cloudflare DNS");
    const logo = spot.locator("[data-brand='cloudflare'] img");
    await expect(logo).toBeVisible();
    expect(await logo.evaluate((img) => img.naturalWidth)).toBeGreaterThan(0);
  }
  await expect(page.locator("[data-package='pro'] [data-test='package-spotlight']")).toHaveCount(0);

  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/packages/stack");
  await expect(page.locator("[data-test='stack-row'][data-feature='cloudflare-dns']")).toBeVisible();
  const flow = page.locator("[data-test='dns-flow']");
  await flow.scrollIntoViewIfNeeded();
  await expect(flow.getByRole("heading", { name: "Cloudflare DNS, in action" })).toBeVisible();
  await expect(flow.locator("[data-test='dns-flow-step']")).toHaveCount(4);
  const pageOverflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
  expect(pageOverflow).toBeLessThanOrEqual(0);
});
