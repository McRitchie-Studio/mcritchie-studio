// [e2e] The hub's branding is its saved Studio kit (task studio-adopts-its-kit).
// `bin/rails logos:install BRAND=studio` wrote public/brand/ from the kit saved
// at /logos/studio; the favicon and the app icon are rasterized from it. The
// navbar, the footer and the sign-in card draw icon-light.svg, and a dark page
// swaps in icon-dark.svg by CSS (application.css, KIT ICON BY THEME). Once the
// engine draws Studio.navbar_wordmark the navbar shows the kit's lockup instead.
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
  await expect(page.locator("link[rel='icon']")).toHaveAttribute("href", "/favicon.png");

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

test("the footer draws the kit icon, never inverted", async ({ page }) => {
  await withTheme(page, "light");
  await page.goto("/");
  const logo = page.locator("footer[data-site-footer] img.ftr-logo");
  await logo.scrollIntoViewIfNeeded();
  await expect(logo).toBeVisible();
  await expect(logo).not.toHaveClass(/ftr-logo-invert/);
  expect(await painted(logo)).toEqual({ src: "/brand/icon-light.svg", shown: "/brand/icon-light.svg", loaded: true });
});
