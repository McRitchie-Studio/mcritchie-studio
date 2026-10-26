// [e2e] The hub's branding is its saved Studio kit (task studio-adopts-its-kit).
// `bin/rails logos:install BRAND=studio` wrote public/brand/ from the kit saved
// at /logos/studio; the favicon and the app icon are rasterized from it. The
// navbar and the sign-in card draw icon-light.svg, and a dark page swaps in
// icon-dark.svg by CSS (application.css, KIT ICON BY THEME). Once the engine
// draws Studio.navbar_wordmark the navbar shows the kit's lockup instead, and
// once it draws the footer's `lockup` fact the footer shows the Stacked Logo.
const { test, expect } = require("@playwright/test");

const withTheme = (page, theme) => page.addInitScript((value) => localStorage.setItem("theme", value), theme);

// The picture a browser actually paints for an <img>: its CSS `content` image when one is set, else its src.
const painted = (img) => img.evaluate((el) => {
  const content = getComputedStyle(el).content;
  const match = /url\("?([^")]+)"?\)/.exec(content || "");
  return { src: el.getAttribute("src"), shown: match ? new URL(match[1], location.href).pathname : el.getAttribute("src"),
           loaded: el.complete && el.naturalWidth > 0 };
});

test("the favicon, app icon and kit files are served as images", async ({ page, request }) => {
  await page.goto("/signin");
  // Bare on the released engine; with its content version once studio-engine
  // links it as /favicon.png?v=<8 hex> (task footer-stacked-logo).
  await expect(page.locator("link[rel='icon']")).toHaveAttribute("href", /^\/favicon\.png(\?v=[0-9a-f]{8})?$/);

  const favicon = await request.get("/favicon.png");
  expect(favicon.status()).toBe(200);
  expect(favicon.headers()["content-type"]).toContain("image/png");
  const appIcon = await request.get("/icon.png");
  expect(appIcon.status()).toBe(200);
  expect(appIcon.headers()["content-type"]).toContain("image/png");

  const light = await request.get("/brand/icon-light.svg");
  expect(light.status()).toBe(200);
  expect(light.headers()["content-type"]).toContain("image/svg+xml");
  const dark = await request.get("/brand/icon-dark.svg");
  expect(dark.status()).toBe(200);
  expect(dark.headers()["content-type"]).toContain("image/svg+xml");
  const navbar = await request.get("/brand/navbar-light.svg");
  expect(navbar.status()).toBe(200);
  expect(navbar.headers()["content-type"]).toContain("image/svg+xml");
});

test("on a light page the sign-in card and the navbar draw the kit's light-page icon", async ({ page }) => {
  await withTheme(page, "light");
  await page.goto("/signin");
  await expect(page.locator("html")).not.toHaveClass(/\bdark\b/);

  const card = page.locator("img.auth-logo");
  await expect(card).toBeVisible();
  expect(await painted(card)).toEqual({ src: "/brand/icon-light.svg", shown: "/brand/icon-light.svg", loaded: true });

  const brand = page.locator("header.nav-shell .nav-logo-link img:visible").first();
  await expect(brand).toBeVisible();
  const navbar = await painted(brand);
  expect(navbar.loaded).toBe(true);
  expect(["/brand/icon-light.svg", "/brand/navbar-light.svg"]).toContain(navbar.shown);
});

test("on a dark page the sign-in card and the navbar swap in the kit's dark-page artwork", async ({ page }) => {
  await withTheme(page, "dark");
  await page.goto("/signin");
  await expect(page.locator("html")).toHaveClass(/\bdark\b/);

  const card = page.locator("img.auth-logo");
  await expect(card).toBeVisible();
  const shown = await painted(card);
  expect(shown.src).toBe("/brand/icon-light.svg");
  expect(shown.shown).toBe("/brand/icon-dark.svg");

  const brand = page.locator("header.nav-shell .nav-logo-link img:visible").first();
  await expect(brand).toBeVisible();
  expect(["/brand/icon-dark.svg", "/brand/navbar-dark.svg"]).toContain((await painted(brand)).shown);
});

// The footer draws the kit's Stacked Logo (task footer-stacked-logo): the
// engine's `lockup` fact renders stacked-light.svg and stacked-dark.svg and its
// CSS shows the one that matches the theme. An engine from before the fact
// draws the kit icon and the wordmark instead, so the check follows whichever
// is bundled; the hub's CI runs the released engine until the release relocks.
const DESKTOP = { width: 1280, height: 900 };
const PHONE = { width: 390, height: 844 };

// One bare test( per case below: the e2e census counts declarations, so no loop.
async function checkFooterLogo(page, viewport, theme) {
  await page.setViewportSize(viewport);
  await withTheme(page, theme);
  await page.goto("/");
  const brand = page.locator("footer[data-site-footer] .ftr-brand");
  await brand.scrollIntoViewIfNeeded();

  if (await brand.locator("img.ftr-lockup").count() === 0) {
    const logo = brand.locator("img.ftr-logo");
    await expect(logo).toBeVisible();
    await expect(logo).not.toHaveClass(/ftr-logo-invert/);
    expect((await painted(logo)).shown).toBe(`/brand/icon-${theme}.svg`);
    return;
  }

  const shown = brand.locator("img.ftr-lockup:visible");
  await expect(shown).toHaveCount(1);
  expect(await painted(shown)).toEqual({ src: `/brand/stacked-${theme}.svg`, shown: `/brand/stacked-${theme}.svg`, loaded: true });
  await expect(shown).toHaveAttribute("alt", "McRitchie Studio");
  await expect(brand.locator(`img.ftr-lockup-${theme === "light" ? "dark" : "light"}`)).toBeHidden();
  await expect(brand.locator("img.ftr-logo, .ftr-wordmark")).toHaveCount(0);

  // Sized like the icon-and-name block it replaced, inside its column, and
  // centred in it with the social row (Alex McRitchie 2026-10-15 08:21: no tagline,
  // centre justified).
  const box = await shown.boundingBox();
  expect(box.height).toBeGreaterThan(96);
  expect(box.height).toBeLessThan(128);
  expect(box.x + box.width).toBeLessThanOrEqual(viewport.width);
  const column = await brand.boundingBox();
  const centre = (b) => b.x + b.width / 2;
  expect(Math.abs(centre(box) - centre(column))).toBeLessThanOrEqual(2);
  const socials = brand.locator(".ftr-socials a");
  await expect(socials).toHaveCount(3);
  const first = await socials.first().boundingBox();
  const last = await socials.last().boundingBox();
  expect(Math.abs((first.x + last.x + last.width) / 2 - centre(column))).toBeLessThanOrEqual(2);
  await expect(brand.locator(".ftr-tagline")).toHaveCount(0);
}

test("the footer shows the kit's stacked logo on a light page at desktop width", async ({ page }) => checkFooterLogo(page, DESKTOP, "light"));
test("the footer shows the kit's stacked logo on a dark page at desktop width", async ({ page }) => checkFooterLogo(page, DESKTOP, "dark"));
test("the footer shows the kit's stacked logo on a light page at phone width", async ({ page }) => checkFooterLogo(page, PHONE, "light"));
test("the footer shows the kit's stacked logo on a dark page at phone width", async ({ page }) => checkFooterLogo(page, PHONE, "dark"));
