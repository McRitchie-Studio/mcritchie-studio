// [e2e] A client app wears the Studio template (docs/agents/system/client-app-host.md,
// "The Studio template"). e2e/seed.rb publishes kit-demo, a bundle that carries only
// its content in <main data-studio-content>; the shared host wraps it at serve time in
// the engine's navbar and footer, in the app's palette. On a phone, the navbar's
// toggle flips dark mode (and keeps the choice across a reload), and its menu opens
// and closes, all under the bundle CSP with no inline script and no console error.
//
// Read-only on the board: it reads only what e2e/seed.rb publishes.
const { test, expect } = require("@playwright/test");
const { VISITOR } = require("./helpers");

test.use({ storageState: VISITOR });

function appURL(baseURL) {
  const url = new URL(baseURL);
  url.hostname = "kit-demo.localhost";
  return url.toString();
}

test("a kit page toggles dark mode and opens its menu on a phone", async ({ page, baseURL }) => {
  const problems = [];
  page.on("console", (message) => { if (message.type() === "error") problems.push(message.text()); });
  page.on("pageerror", (error) => problems.push(error.message));

  await page.setViewportSize({ width: 390, height: 844 });
  await page.emulateMedia({ colorScheme: "light" });
  const response = await page.goto(appURL(baseURL));
  expect(response.status()).toBe(200);
  expect(response.headers()["content-security-policy"]).toContain("script-src 'self'");

  const navbar = page.locator("body > header[data-studio-navbar]");
  await expect(navbar).toBeVisible();
  await expect(navbar.locator(".nav-title")).toHaveText(/Table\s*Ready/);
  await expect(page.locator("main[data-studio-content] h1")).toHaveText("Book a table tonight");
  const footer = page.locator("body > footer[data-studio-footer]");
  await expect(footer.getByRole("link", { name: "Built with McRitchie Studio" })).toHaveAttribute("href", "https://mcritchie.studio");

  const html = page.locator("html");
  await expect(html).not.toHaveClass(/dark/);
  const lightPage = await page.evaluate(() => getComputedStyle(document.body).backgroundColor);

  const toggle = navbar.locator("[data-studio-kit-theme-toggle]");
  await expect(toggle).toHaveAttribute("aria-pressed", "false");
  await toggle.click();
  await expect(html).toHaveClass(/dark/);
  await expect(toggle).toHaveAttribute("aria-pressed", "true");
  const darkPage = await page.evaluate(() => getComputedStyle(document.body).backgroundColor);
  expect(darkPage, "the app's own content follows the toggle (its --surface switched)").not.toBe(lightPage);
  expect(darkPage).toBe("rgb(28, 25, 23)");

  await page.reload();
  await expect(html, "the choice survives a reload").toHaveClass(/dark/);

  const menuButton = navbar.locator("[data-studio-kit-menu-toggle]");
  const menu = page.locator("#studio-kit-menu");
  await expect(menu).toBeHidden();
  await menuButton.click();
  await expect(menu).toBeVisible();
  await expect(menuButton).toHaveAttribute("aria-expanded", "true");
  await expect(menu.getByRole("link", { name: "Build your own app" })).toHaveAttribute("href", "https://mcritchie.studio/build");
  const box = await menu.boundingBox();
  expect(box.x, "the menu stays on screen at 390px").toBeGreaterThanOrEqual(0);
  expect(box.x + box.width).toBeLessThanOrEqual(390);
  await page.keyboard.press("Escape");
  await expect(menu).toBeHidden();
  await expect(menuButton).toHaveAttribute("aria-expanded", "false");

  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
  expect(overflow, "nothing runs off the side at 390px").toBeLessThanOrEqual(0);
  expect(problems, "no CSP violation or script error").toEqual([]);
});
