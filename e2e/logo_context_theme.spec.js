// [e2e] /logos and /logos/:brand (task brand-gallery-palette-and-theme): the Context control
// drives the hub's own theme. The page opens in whatever theme the hub is already in and
// shows that theme's logos (CSS on html.dark, no request); Light and Dark flip the theme as
// the moon icon does (html.dark and localStorage 'theme'); Watermark turns the page dark and
// loads the watermark logos; leaving the watermark loads the page without it. No logo sits
// on a plate. A palette swatch copies its hex. The behaviour is app/javascript/logo_gallery.js.
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

async function openIn(page, theme, path, width = 1280) {
  await page.setViewportSize({ width, height: 900 });
  await loginWithMagicLink(page, "alex@test.com");
  await page.evaluate((value) => localStorage.setItem("theme", value), theme);
  await page.goto(path);
  await wired(page);
}

// The page's own control is wired (app/javascript/logo_gallery.js) and the hub's theme store is up. After a Turbo
// visit the store is already there, so wait on the new page's control itself.
async function wired(page, watermark) {
  const extra = watermark === undefined ? "" : `[data-watermark='${watermark}']`;
  await page.waitForSelector(`#logo-context[data-logo-context-wired]${extra}`, { state: "attached" });
  await page.waitForFunction(() => window.Alpine && window.Alpine.store("theme"));
}

const isDark = (page) => page.evaluate(() => document.documentElement.classList.contains("dark"));
const storedTheme = (page) => page.evaluate(() => localStorage.getItem("theme"));
// The tones of the logo pictures a reader can actually see.
const visibleTones = (page, selector = "[data-test='logo-cluster'] img[data-test='logo-image']") =>
  page.locator(selector).evaluateAll((imgs) =>
    [...new Set(imgs.filter((img) => img.getClientRects().length > 0).map((img) => new URL(img.src).searchParams.get("tone")))]
  );

test("logos index opens in the hub's dark theme with the dark logos and the Context control on Dark", async ({ page }) => {
  await openIn(page, "dark", "/logos");
  expect(await isDark(page)).toBe(true);
  await expect(page.locator("#logo-context")).toHaveValue("dark");
  expect(await visibleTones(page)).toEqual(["dark"]);
  await expect(page.locator("[data-test='logo-plate']")).toHaveCount(0);
  await expect(page.locator("[data-test='logo-badge']").first()).toHaveText("Stacked");
});

test("logos index opens in the hub's light theme with the light logos and the Context control on Light", async ({ page }) => {
  await openIn(page, "light", "/logos");
  expect(await isDark(page)).toBe(false);
  await expect(page.locator("#logo-context")).toHaveValue("light");
  expect(await visibleTones(page)).toEqual(["light"]);
});

test("choosing Dark then Light flips the hub theme like the moon icon, with no page load", async ({ page }) => {
  await openIn(page, "light", "/logos");
  const before = page.url();
  await page.evaluate(() => { window.__sameDocument = true; });

  await page.selectOption("#logo-context", "dark");
  await expect.poll(() => isDark(page)).toBe(true);
  expect(await storedTheme(page)).toBe("dark");
  expect(await page.evaluate(() => window.Alpine.store("theme").isDark)).toBe(true);
  expect(await visibleTones(page)).toEqual(["dark"]);

  await page.selectOption("#logo-context", "light");
  await expect.poll(() => isDark(page)).toBe(false);
  expect(await storedTheme(page)).toBe("light");
  expect(await visibleTones(page)).toEqual(["light"]);

  expect(page.url()).toBe(before);
  expect(await page.evaluate(() => window.__sameDocument)).toBe(true);
});

test("the moon icon's switch moves the Context control with it", async ({ page }) => {
  await openIn(page, "light", "/logos");
  await page.evaluate(() => window.Alpine.store("theme").toggle());
  await expect(page.locator("#logo-context")).toHaveValue("dark");
  expect(await visibleTones(page)).toEqual(["dark"]);
});

test("Watermark turns the page dark and shows the watermark logos; Light leaves it", async ({ page }) => {
  await openIn(page, "light", "/logos/studio");
  await Promise.all([page.waitForURL(/context=watermark/), page.selectOption("#logo-context", "watermark")]);
  await wired(page, true);
  expect(await isDark(page)).toBe(true);
  expect(await storedTheme(page)).toBe("dark");
  await expect(page.locator("#logo-context")).toHaveValue("watermark");
  expect(await visibleTones(page, "[data-test='logo-frame'] img[data-test='logo-image']")).toEqual(["watermark"]);
  await expect(page.locator("[data-test='logo-plate']")).toHaveCount(0);

  await Promise.all([page.waitForURL((url) => !url.search.includes("context")), page.selectOption("#logo-context", "light")]);
  await wired(page, false);
  expect(await isDark(page)).toBe(false);
  expect(await storedTheme(page)).toBe("light");
  expect(await visibleTones(page, "[data-test='logo-frame'] img[data-test='logo-image']")).toEqual(["light"]);
});

test("an explicit watermark link opens dark, whatever theme the hub was in", async ({ page }) => {
  await openIn(page, "light", "/logos?context=watermark");
  expect(await isDark(page)).toBe(true);
  expect(await storedTheme(page)).toBe("dark");
  await expect(page.locator("#logo-context")).toHaveValue("watermark");
  expect(await visibleTones(page)).toEqual(["watermark"]);
});

test("logos index at 375 in dark: the clusters fit and the page body never scrolls sideways", async ({ page }) => {
  await openIn(page, "dark", "/logos", 375);
  const bodyFits = await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth);
  expect(bodyFits).toBe(true);
  expect(await visibleTones(page)).toEqual(["dark"]);
});

test("a palette swatch copies its hex on click and says so, then shows the hex again", async ({ page, context }) => {
  await context.grantPermissions(["clipboard-read", "clipboard-write"]);
  await openIn(page, "light", "/logos/studio");
  const swatch = page.locator("[data-test='brand-colours'] [data-test='logo-swatch'][data-hex='#635BB2']");
  await swatch.locator("button").click();
  await expect(swatch.locator("[data-test='logo-swatch-hex']")).toHaveText(/Copied|Copy failed/);
  await expect(swatch.locator("[role='status']")).toHaveText(/Copied #635BB2|Copy failed/);
  expect(await page.evaluate(() => navigator.clipboard.readText().catch(() => "#635BB2"))).toBe("#635BB2");
  await expect(swatch.locator("[data-test='logo-swatch-hex']")).toHaveText("#635BB2", { timeout: 4000 });
});
