// [e2e] The logo gallery's polish pass (task logo-gallery-polish-pass): the edit panel's Reset is a
// full-size touch target on a phone, a kit original's Delete asks first, the Kit card's button rows
// line up, a Copy SVG fetches the logo from its own URL and says Copied, and a shared context link
// opens in its theme from the first paint.
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

async function open(page, path, width = 1280) {
  await page.setViewportSize({ width, height: 900 });
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto(path);
}

// Written as literal tests, not a loop: bin/e2e-executed-set-check counts `test(` calls in the source.
test("the edit panel's Reset is at least 40 px tall at 375 px", async ({ page }) => {
  await open(page, "/logos/studio?first_colour=635BB2", 375);
  const box = await page.locator("[data-test='edit-reset']").boundingBox();
  expect(box.height).toBeGreaterThanOrEqual(40);
  expect(box.width).toBeGreaterThanOrEqual(40);
});

test("deleting a kit original asks first: Delete opens the question, Cancel closes it, and the named button deletes", async ({ page }) => {
  await open(page, "/logos/turf?type=icon");
  const card = page.locator("[data-test='kit-originals']");
  await card.locator("input[type='file']").setInputFiles([
    { name: "turf-polish.svg", mimeType: "image/svg+xml", buffer: Buffer.from('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><rect width="10" height="10"/></svg>') }
  ]);
  await card.locator("[data-test='kit-original-upload']").click();
  await page.waitForURL(/#kit-originals/);
  const item = page.locator("[data-test='kit-original']").filter({ hasText: "turf-polish.svg" });
  const confirm = item.locator("[data-test='kit-original-delete-confirm']");
  await expect(confirm).toBeHidden();

  // By keyboard: the first step is a focusable control, and Enter opens it.
  await item.locator("[data-test='kit-original-delete']").focus();
  await page.keyboard.press("Enter");
  await expect(confirm).toBeVisible();
  await expect(confirm).toHaveText("Delete turf-polish.svg");
  await expect(item.locator("[data-test='kit-original-delete']")).toContainText("Cancel");
  await page.keyboard.press("Enter");
  await expect(confirm).toBeHidden();
  await expect(item).toHaveCount(1);

  await item.locator("[data-test='kit-original-delete']").click();
  await confirm.click();
  await expect(page.getByText("Removed turf-polish.svg.")).toBeVisible();
  await expect(page.locator("[data-test='kit-original']").filter({ hasText: "turf-polish.svg" })).toHaveCount(0);
});

test("saving and clearing a kit choice return to the same tab, scrolled to the Kit choice card", async ({ page }) => {
  await open(page, "/logos/studio?type=stacked&form=tagline");
  // Scrolled to the card, and the card's heading clear of the sticky navbar.
  const inView = () => page.evaluate(() => {
    const top = document.querySelector("[data-test='kit-choice']").getBoundingClientRect().top;
    const navBottom = document.querySelector("header").getBoundingClientRect().bottom;
    return window.scrollY > 0 && top >= navBottom - 1 && top < window.innerHeight / 2;
  });

  await page.locator("[data-test='kit-save']").click();
  // The saved choice is the tab's default (task logo-original-and-alt), so saving returns to the bare tab.
  await page.waitForURL(/\/logos\/studio\?type=stacked#kit-choice$/);
  await expect(page.getByText(/Saved the Stacked Logo kit choice/)).toBeAttached();
  await expect.poll(inView).toBe(true);

  await page.locator("[data-test='kit-clear']").click();
  await page.waitForURL(/\/logos\/studio\?(?=.*type=stacked)(?=.*form=tagline).*#kit-choice$/);
  await expect(page.getByText("Cleared the Stacked Logo kit choice. The brand shows its default again.")).toBeAttached();
  await expect.poll(inView).toBe(true);
});

test("at 1280 a saved kit leaves no brand's logo tiles wrapped", async ({ page }) => {
  await open(page, "/logos/industries?type=stacked");
  await page.locator("[data-test='kit-save']").click();
  await page.waitForURL(/#kit-choice$/);
  try {
    await page.goto("/logos");
    // Task brand-kit-applied-status: the brand column no longer prints a "Kit: saved … by" line; it lists each app the
    // kit feeds (component-tested in test/controllers/brand_kit_app_status_test.rb).
    await expect(page.locator("[data-test='logo-kit-status']")).toHaveCount(0);
    const rows = await page.evaluate(() => Array.from(document.querySelectorAll("[data-test='logo-cluster']")).map((cluster) => {
      const top = (type) => cluster.querySelector(`[data-test='logo-sample'][data-type='${type}']`).getBoundingClientRect().top;
      return { brand: cluster.dataset.brand, sameLine: Math.abs(top("stacked") - top("navbar")) < 1 };
    }));
    for (const row of rows) expect(row, row.brand).toEqual({ brand: row.brand, sameLine: true });
  } finally {
    await page.goto("/logos/industries?type=stacked");
    await page.locator("[data-test='kit-clear']").click();
    await page.waitForURL(/#kit-choice$/);
  }
});

test("at 1280 the Kit card's button rows line up", async ({ page }) => {
  await open(page, "/logos/welding_v2?type=stacked");
  const rows = page.locator("[data-test='kit-card'] [data-test='kit-pick-actions']");
  // Three picks since task kit-icon-atomic-unit: the Icon, the Navbar and the Stacked Logo.
  await expect(rows).toHaveCount(3);
  const [icon, navbar, stacked] = [await rows.nth(0).boundingBox(), await rows.nth(1).boundingBox(), await rows.nth(2).boundingBox()];
  expect(Math.abs(navbar.y - stacked.y)).toBeLessThan(1);
  expect(Math.abs(icon.y - stacked.y)).toBeLessThan(1);
});

test("Copy SVG fetches the logo from its own URL on click, puts it on the clipboard and says Copied", async ({ page, context }) => {
  await context.grantPermissions(["clipboard-read", "clipboard-write"]);
  // The brand page's Copy SVG went with task brand-page-split-layout; Compare keeps one per logo.
  await open(page, "/logos/compare?left=turf&right=studio");
  const copy = page.locator("[data-test='logo-copy']:visible").first();
  const url = await copy.getAttribute("data-copy-svg");
  expect(url).toMatch(/^\/logos\/turf\/navbar\?/);
  expect(url).not.toContain("download");
  expect(await copy.getAttribute("data-clip")).toBeNull();

  const fetched = page.waitForResponse((response) => response.url().endsWith(url) && response.request().resourceType() === "fetch");
  await copy.click();
  // The fetch may be answered from the picture's cache (a 304 carries no body or type), so the SVG is read afresh.
  await fetched;
  await expect(copy).toHaveText("Copied");
  const svg = await (await page.request.get(url)).text();
  expect(svg.startsWith("<svg")).toBe(true);
  expect(await page.evaluate(() => navigator.clipboard.readText())).toBe(svg);
  await expect(copy).toHaveText("Copy SVG", { timeout: 4000 });
});

test("Copy SVG says Copy failed when the logo cannot be fetched", async ({ page, context }) => {
  await context.grantPermissions(["clipboard-read", "clipboard-write"]);
  await open(page, "/logos/compare?left=studio&right=turf");
  await page.route(/\/logos\/studio\/navbar\?/, (route) => (route.request().resourceType() === "fetch" ? route.fulfill({ status: 500, body: "no" }) : route.continue()));
  const copy = page.locator("[data-test='logo-copy']:visible").first();
  await copy.click();
  await expect(copy).toHaveText("Copy failed");
  await expect(page.locator("[data-copy-svg-status]").filter({ hasText: "Copy failed" })).toHaveCount(1);
});

// The root's theme at the first animation frame, which is the theme the first paint draws: recorded by a script that
// runs before any of the page's own.
async function firstFrameDark(page, path) {
  await page.addInitScript(() => {
    requestAnimationFrame(() => { window.__firstFrameDark = document.documentElement.classList.contains("dark"); });
  });
  await page.goto(path);
  await page.waitForFunction(() => window.__firstFrameDark !== undefined);
  return page.evaluate(() => window.__firstFrameDark);
}

test("a shared ?context=light link paints light from the first frame, over a stored dark theme", async ({ page }) => {
  await open(page, "/logos");
  await page.evaluate(() => localStorage.setItem("theme", "dark"));
  expect(await firstFrameDark(page, "/logos/studio?context=light")).toBe(false);
  expect(await page.evaluate(() => localStorage.getItem("theme"))).toBe("light");
  await expect(page.locator("html")).not.toHaveClass(/\bdark\b/);
});

test("a shared ?context=dark or watermark link paints dark from the first frame, over a stored light theme", async ({ page }) => {
  await open(page, "/logos");
  await page.evaluate(() => localStorage.setItem("theme", "light"));
  expect(await firstFrameDark(page, "/logos?context=dark")).toBe(true);
  expect(await page.evaluate(() => localStorage.getItem("theme"))).toBe("dark");
  await page.evaluate(() => localStorage.setItem("theme", "light"));
  expect(await firstFrameDark(page, "/logos/turf?context=watermark")).toBe(true);
  await expect(page.locator("[data-test='logo-example'][data-tones='watermark']").first()).toBeVisible();
});
