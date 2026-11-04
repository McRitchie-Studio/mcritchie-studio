const { test, expect } = require("@playwright/test");
const { CONTRAST } = require("./contrast");

// [e2e] The admin sidebar's first section is the four main areas, and the Basement
// (/admin/basement) is the page of links the rest live on. A moved page stays one
// click away, at its old address, and the page holds at phone width in both themes.
const MOVED = [
  { href: "/admin/schema", label: "Schema", desc: "DB schema browser" },
  { href: "/logos", label: "Logos", desc: "navbar logos" },
  { href: "/admin/emails", label: "Emails", desc: "Transactional emails" },
  { href: "/admin/link_preview", label: "Link preview", desc: "Default title" },
  { href: "/assets", label: "Assets", desc: "Object store" },
];
const PHONE = { name: "phone", width: 390, height: 844 };
const DESKTOP = { name: "desktop", width: 1440, height: 900 };
// The muted section word is the faintest text the page draws, as on the sub-navs.
const LEGIBLE = 3.0;

const setTheme = (page, theme) =>
  page.evaluate((t) => document.documentElement.classList.toggle("dark", t === "dark"), theme);

const listsTheMovedPages = async (page, size) => {
  await page.setViewportSize({ width: size.width, height: size.height });
  await page.goto("/admin/basement");

  await expect(page.getByRole("heading", { level: 1, name: "Basement" })).toBeVisible();
  const hub = page.locator("[data-link-hub]");
  for (const { href, label, desc } of MOVED) {
    const link = hub.locator(`a[href='${href}']`);
    await expect(link).toBeVisible();
    await expect(link).toContainText(label);
    await expect(link).toContainText(desc);
  }

  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
  expect(overflow, "the page must not scroll sideways").toBeLessThanOrEqual(0);

  for (const theme of ["dark", "light"]) {
    await setTheme(page, theme);
    // Links ease between theme colours, so the faintest is polled until it settles.
    await expect
      .poll(
        async () => {
          const ratios = await page.evaluate(CONTRAST, "[data-link-hub] a, [data-link-hub] h2");
          return ratios.length ? Math.min(...ratios.map(({ ratio }) => ratio)) : 0;
        },
        { message: `the faintest Basement text in ${theme} at ${size.name}`, timeout: 5_000 }
      )
      .toBeGreaterThanOrEqual(LEGIBLE);
  }
};

test("the Basement lists the moved pages at phone width, in both themes", async ({ page }) => {
  await listsTheMovedPages(page, PHONE);
});

test("the Basement lists the moved pages at desktop width, in both themes", async ({ page }) => {
  await listsTheMovedPages(page, DESKTOP);
});

test("the sidebar reads Dashboard, DevOps, Design, Basement and takes you to the Basement", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto("/dashboard");
  await page.waitForFunction(() => window.Alpine && Alpine.store("sidebars"));
  await page.locator("button[data-link-sidebar-trigger]:visible").first().click();

  const sidebar = page.locator("#studio-link-sidebar");
  await expect(sidebar).toBeVisible();
  for (const [href, word] of [
    ["/admin/dashboard", "Dashboard"],
    ["/deployments", "DevOps"],
    ["/admin/style", "Design"],
    ["/admin/basement", "Basement"],
  ]) {
    await expect(sidebar.locator(`a[href='${href}']`)).toContainText(word);
  }
  for (const { href } of MOVED) await expect(sidebar.locator(`a[href='${href}']`)).toHaveCount(0);

  await sidebar.locator("a[href='/admin/basement']").click();
  await expect(page).toHaveURL("/admin/basement");
  await expect(page.locator("[data-link-hub] a[href='/assets']")).toBeVisible();
});

test("a moved page still opens from its old address, one click from the Basement", async ({ page }) => {
  await page.goto("/admin/basement");
  await page.locator("[data-link-hub] a[href='/assets']").click();
  await expect(page).toHaveURL("/assets");
  await expect(page.getByRole("heading", { level: 1 }).first()).toBeVisible();
});
