const { test, expect } = require("@playwright/test");
const { VISITOR } = require("./helpers");

// What a visitor sees: signed out, not the suite's default admin session.
test.use({ storageState: VISITOR });

// /packages and /packages/stack (task tiered-packages-and-full-stack; the
// 2026-10-12 ladder from task cto-and-team-tiers: Vibe, Builder, Pro and Team cards,
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
  await expect(cards.locator("h2")).toHaveText(["Vibe", "Builder", "Pro", "Team"]);
  await expect(page.locator("[data-test='package-card'][data-package='team'] [data-test='price-monthly']")).toContainText("$900");

  // The cards line up at desktop width: equal heights, and every CTA and
  // first group heading at the same height, however the taglines wrap.
  await page.setViewportSize({ width: 1440, height: 900 });
  const tops = async (selector) => page.locator(selector).evaluateAll((els) => els.map((el) => Math.round(el.getBoundingClientRect().top)));
  const heights = await cards.evaluateAll((els) => els.map((el) => Math.round(el.getBoundingClientRect().height)));
  expect(new Set(heights).size).toBe(1);
  expect(new Set(await tops("[data-test='package-card'] [data-test='package-cta']")).size).toBe(1);
  // Swim lanes: every group heading and every lane sits at one height across
  // the cards that show it, even where a subtext wraps in one card and not another.
  const laneTops = await page.locator("[data-test='package-line'], [data-test='package-line-group']").evaluateAll((els) => {
    const byKey = {};
    for (const el of els) {
      const key = el.dataset.lane || `group:${el.dataset.group}`;
      (byKey[key] ||= []).push(Math.round(el.getBoundingClientRect().top));
    }
    return byKey;
  });
  expect(Object.keys(laneTops).length).toBe(17);
  for (const [key, offsets] of Object.entries(laneTops)) {
    expect(new Set(offsets).size, `${key} at ${offsets}`).toBe(1);
  }
  expect(laneTops["host_storage"].length).toBe(4);
  expect(laneTops["cmo"].length).toBe(2);
  // Every lane's subtext is one line at a 1280px desktop: short copy, never a
  // wrap or an ellipsis, so new copy cannot regress the swim lanes.
  await page.setViewportSize({ width: 1280, height: 900 });
  const subs = await page.locator("[data-test='package-card'] [data-test='line-sub']").evaluateAll((els) => els.map((el) => ({
    text: el.textContent.trim(),
    ratio: el.getBoundingClientRect().height / parseFloat(getComputedStyle(el).lineHeight),
    clipped: el.scrollWidth > el.clientWidth,
  })));
  expect(subs.length).toBeGreaterThan(20);
  for (const sub of subs) {
    expect(sub.ratio, `"${sub.text}" wraps`).toBeLessThanOrEqual(1.5);
    expect(sub.clipped, `"${sub.text}" is cut off`).toBe(false);
  }
  await page.setViewportSize({ width: 1440, height: 900 });

  // The Most popular badge is fully inside the page, not clipped at the card's edge.
  const badge = await page.locator("[data-test='featured-badge']").boundingBox();
  const teamCard = await page.locator("[data-test='package-card'][data-package='team']").boundingBox();
  expect(badge.y).toBeGreaterThanOrEqual(teamCard.y);
  // The Vibe hostname never breaks at its hyphen.
  const host = page.locator("[data-package='vibe'] [data-test='tagline-host']");
  const hostLines = await host.evaluate((el) => Math.round(el.getBoundingClientRect().height / parseFloat(getComputedStyle(el).lineHeight)));
  expect(hostLines).toBe(1);

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
  const pro = page.locator("[data-test='package-card'][data-package='pro']");
  await expect(pro.locator("[data-test='price-monthly']")).toBeVisible();
  await page.locator("[data-test='billing-annual']").click();
  await expect(pro.locator("[data-test='price-annual']")).toContainText("$450");
  await expect(pro.locator("[data-test='price-monthly']")).toBeHidden();

  // Pro's CTA opens the booking dialog on this page, not /schedule.
  await pro.locator("[data-test='package-cta']").click();
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

  // The narrow feature column leaves the first tier in full view, row
  // descriptions hide, and a one-brand row leads with that brand's logo. (Two
  // tiers fit until 2026-10-12; the domain pills now never break inside a
  // hostname, so the columns size to "mcritchie.studio" and the box scrolls.)
  const boxRight = await box.evaluate((el) => el.getBoundingClientRect().right);
  const vibeRight = await page.locator("[data-test='stack-tier-header'][data-package='vibe']")
    .evaluate((el) => el.getBoundingClientRect().right);
  expect(vibeRight).toBeLessThanOrEqual(boxRight);
  // A hostname pill wraps only at a label boundary, never mid-word.
  const vibeHost = page.locator("[data-feature='web-address'] [data-test='stack-cell'][data-package='vibe'] [data-test='stack-hostname']");
  const hostLines = await vibeHost.evaluate((el) =>
    Math.round(el.getBoundingClientRect().height / parseFloat(getComputedStyle(el).lineHeight)));
  expect(hostLines).toBeLessThanOrEqual(2);
  await expect(page.locator("[data-test='stack-blurb']").first()).toBeHidden();
  const serverLogo = page.locator("[data-feature='host'] [data-test='stack-lead'] [data-brand='heroku'] img");
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

test("Pro and Team cards mark their lines, tease the next tier, and the full stack draws the Cloudflare row on a phone", async ({ page }) => {
  await page.goto("/packages");

  // A check for included, a muted cross naming the next tier, Coming soon for promises.
  const pro = page.locator("[data-test='package-card'][data-package='pro']");
  await expect(pro.locator("[data-mark='included']").first()).toHaveAttribute("aria-label", "Included");
  await expect(pro.locator("[data-test='package-line'][data-status='missing']")).toHaveCount(2);
  await expect(pro.locator("[data-test='package-line'][data-lane='drafting'][data-status='missing']")).toContainText("(In Team)");
  const teaser = pro.locator("[data-test='package-line'][data-lane='cmo'][data-status='missing']");
  await expect(teaser).toContainText("Fractional CMO");
  await expect(teaser).toContainText("(In Team)");
  await expect(teaser.locator("[data-mark='missing']")).toHaveAttribute("aria-label", "In Team");
  const team = page.locator("[data-test='package-card'][data-package='team']");
  await expect(team.locator("[data-test='package-line'][data-status='soon'] [data-test='coming-soon']")).toHaveCount(2);
  await expect(pro.locator("[data-test='package-line'][data-lane='domain']")).toContainText("Premium Domain");
  await expect(pro.locator("[data-test='package-line'][data-lane='domain']")).toContainText("best-in-class speed & security");
  await expect(pro.locator("[data-test='package-line'][data-lane='cto']")).toContainText("24-hour access & daily summaries");
  await expect(page.locator("[data-test='package-spotlight']")).toHaveCount(0);

  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/packages/stack");
  await expect(page.locator("[data-test='stack-row'][data-feature='fast-protected-domain']")).toBeVisible();
  const flow = page.locator("[data-test='dns-flow']");
  await flow.scrollIntoViewIfNeeded();
  await expect(flow.getByRole("heading", { name: "Your domain on Cloudflare, in action" })).toBeVisible();
  await expect(flow.locator("[data-test='dns-flow-step']")).toHaveCount(4);
  const pageOverflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
  expect(pageOverflow).toBeLessThanOrEqual(0);

  // A tablet (iPad landscape) neither: the five-column matrix scrolls in its box.
  await page.setViewportSize({ width: 1024, height: 768 });
  await page.goto("/packages/stack");
  const tabletOverflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
  expect(tabletOverflow).toBeLessThanOrEqual(0);
});
