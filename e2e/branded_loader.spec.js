const { test, expect } = require("@playwright/test");
const { VISITOR, watchPageErrors } = require("./helpers");

// [e2e] The hub shows its branded loader during a slow navigation (task
// branded-app-loader; studio-engine docs/LOADER.md). The Studio style is
// Sparkle on the kit's violet icon. The overlay is hidden on arrival, shows
// once a Turbo visit outlasts its 350ms delay, and goes again when the page
// lands. (That a fast visit never flashes it is the engine's unit test,
// test/javascript/loader.test.mjs: a timing claim a CI browser cannot hold.)
// The slow server is simulated by holding
// the visit's response, so the spec needs no slow route of its own.

test.use({ storageState: VISITOR });

const overlay = (page) => page.locator("[data-studio-loader-overlay]");

async function holdResponses(page, pathname, ms) {
  await page.route((url) => url.pathname === pathname, async (route) => {
    await new Promise((resolve) => setTimeout(resolve, ms));
    await route.continue();
  });
}

test("a slow navigation shows the Sparkle loader until the page arrives", async ({ page }) => {
  const errors = watchPageErrors(page);
  // The suite's use.reducedMotion is inert in the page (e2e/deployments_exit_fx.spec.js);
  // set it here, or a reduced-motion run would draw no sparkles and name no animation.
  await page.emulateMedia({ reducedMotion: "no-preference" });
  await page.goto("/about");
  await expect(overlay(page)).toBeHidden();

  await holdResponses(page, "/packages", 2000);
  await page.evaluate(() => window.Turbo.visit("/packages"));

  await expect(overlay(page)).toBeVisible({ timeout: 1500 });
  const loader = overlay(page).locator('.studio-loader[data-loader-style="sparkle"]');
  await expect(loader.locator("img.studio-loader-icon")).toHaveAttribute("src", "/brand/icon-dark.svg");
  await expect(loader.locator("path.studio-loader-sparkle")).toHaveCount(5);
  expect(await loader.locator("path.studio-loader-sparkle").first().evaluate((el) => getComputedStyle(el).animationName))
    .toBe("studio-loader-twinkle");

  await page.waitForURL("**/packages");
  await expect(overlay(page)).toBeHidden();
  expect(errors.pageErrors, errors.report()).toHaveLength(0);
});

// [e2e] A background refresh never shows the overlay (studio-engine
// loader-skips-background-visits). usage_countdown.js refreshes /build/<token>
// with Turbo.visit(location.href, { action: "replace" }) once the month turns;
// the visitor did not ask for that visit, so it must stay quiet however slow.
test("a countdown's replace visit on /build/<token> never shows the loader", async ({ page }) => {
  const errors = watchPageErrors(page);
  await page.setExtraHTTPHeaders({ "X-Forwarded-For": `198.51.100.${1 + Math.floor(Math.random() * 250)}` });
  await page.goto("/build");
  const box = page.getByLabel("Tell Alex what you want to build");
  await box.fill(`A loader check ${Date.now()}`);
  await page.waitForTimeout(2200);
  await box.press("Enter");
  await page.waitForURL(/\/build\/[^/]+$/);
  const pathname = new URL(page.url()).pathname;

  await holdResponses(page, pathname, 1500);
  const shown = page.evaluate(() => new Promise((resolve) => {
    const el = document.querySelector("[data-studio-loader-overlay]");
    let seen = false;
    const timer = setInterval(() => { if (el && getComputedStyle(el).display !== "none" && !el.hidden) seen = true; }, 20);
    window.Turbo.visit(window.location.href, { action: "replace" });
    setTimeout(() => { clearInterval(timer); resolve(seen); }, 1200);
  }));
  expect(await shown).toBe(false);
  expect(errors.pageErrors, errors.report()).toHaveLength(0);
});
