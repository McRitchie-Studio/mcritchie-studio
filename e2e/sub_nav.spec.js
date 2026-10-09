const fs = require("fs");
const path = require("path");
const { test, expect } = require("@playwright/test");
const { VISITOR } = require("./helpers");
const { CONTRAST } = require("./contrast");

// [component] The section sub-navs and the link sidebar draw from one registry
// (config/navigation.yml), and that registry is also the admin wall's public page
// list. So the two halves of this spec are the two audiences: a visitor reaches
// the public entries and is sent to sign-in by every page a sub-nav belongs to,
// and an admin gets each sub-nav, with the current page marked, legible in both
// themes and inside the viewport at phone and desktop width.

// Each page a sub-nav sits on: its path, the sub-navs it draws, and the link that
// marks the page itself (null where the sub-nav leaves the current page out).
const PAGES = [
  { path: "/tasks", navs: ["board_sections", "board_views"], current: null },
  { path: "/deployments", navs: ["board_sections", "board_views"], current: null },
  { path: "/stages", navs: ["board_sections", "board_views"], current: "/stages" },
  { path: "/epics", navs: ["board_sections"], current: "/epics" },
  { path: "/triage", navs: ["board_sections", "board_views"], current: null },
  { path: "/xan/heartbeat", navs: ["heartbeat"], current: null },
  { path: "/xan/heartbeat/activities", navs: ["heartbeat"], current: "/xan/heartbeat/activities" },
  { path: "/xan/pipeline", navs: ["heartbeat"], current: null },
];
const WIDTHS = [
  { name: "phone", width: 390, height: 844 },
  { name: "desktop", width: 1440, height: 900 },
];
// The small muted link row is the faintest text a sub-nav draws; this floor holds
// every link to "readable in both themes", above the 3.0 a UI control needs.
const LEGIBLE = 3.0;

// SUB_NAV_SHOTS=<dir> also saves a screenshot per page, width and theme.
const shot = async (page, name) => {
  const dir = process.env.SUB_NAV_SHOTS;
  if (!dir) return;
  fs.mkdirSync(dir, { recursive: true });
  await page.screenshot({ path: path.join(dir, `${name}.png`) });
};

const setTheme = (page, theme) =>
  page.evaluate((t) => document.documentElement.classList.toggle("dark", t === "dark"), theme);

test.describe("a visitor", () => {
  test.use({ storageState: VISITOR });

  test("is sent to sign-in by every page a sub-nav belongs to", async ({ page, request }) => {
    for (const { path: target } of PAGES) {
      const res = await request.get(target, { maxRedirects: 0 });
      expect(res.status(), `${target} is walled`).toBe(302);
      expect(new URL(res.headers()["location"], "http://host").pathname, `${target} redirects to sign-in`).toBe(
        "/login"
      );
    }

    await page.goto("/tasks");
    expect(new URL(page.url()).pathname).toMatch(/^\/(login|signin)$/);
    await expect(page.locator("[data-sub-nav]")).toHaveCount(0);
    await shot(page, "visitor-tasks-desktop");
  });

  test("gets the public sections of the link hub and none of the admin entries", async ({ page }) => {
    await page.goto("/links");
    expect(new URL(page.url()).pathname).toBe("/links");

    const main = page.locator("div.max-w-5xl");
    for (const href of ["/nfl", "/games/2026", "/build", "/packages"]) {
      await expect(main.locator(`a[href='${href}']`), `${href} is a public entry`).toHaveCount(1);
    }
    for (const href of ["/tasks", "/dashboard", "/admin/dashboard", "/deployments", "/agents", "/people", "/docs"]) {
      await expect(main.locator(`a[href='${href}']`), `${href} is an admin entry`).toHaveCount(0);
    }
    await expect(main.locator("h2", { hasText: /^Studio$/ })).toHaveCount(0);
    await shot(page, "visitor-links-desktop");
  });
});

test("an admin gets each sub-nav, marked, legible and inside the viewport in both themes", async ({ page }) => {
  test.setTimeout(120_000);

  for (const size of WIDTHS) {
    await page.setViewportSize({ width: size.width, height: size.height });

    for (const { path: target, navs, current } of PAGES) {
      await page.goto(target);
      expect(new URL(page.url()).pathname, `${target} answers an admin`).toBe(target);

      for (const nav of navs) {
        await expect(page.locator(`nav[data-sub-nav='${nav}']`), `${target} draws ${nav}`).toHaveCount(1);
      }

      const marked = page.locator("nav[data-sub-nav] a[aria-current='page']");
      if (current) {
        await expect(marked, `${target} marks its own link`).toHaveCount(1);
        await expect(marked).toHaveAttribute("href", current);
      } else {
        await expect(marked, `${target} has no link to itself`).toHaveCount(0);
      }

      // Every link the viewer can see sits inside the viewport: a row that ran
      // off the right edge would scroll the page sideways.
      const boxes = await page.evaluate(() =>
        [...document.querySelectorAll("nav[data-sub-nav] a")]
          .filter((link) => link.offsetParent !== null)
          .map((link) => {
            const rect = link.getBoundingClientRect();
            return { text: link.textContent.trim(), left: rect.left, right: rect.right, width: rect.width };
          })
      );
      expect(boxes.length, `${target} shows sub-nav links at ${size.name}`).toBeGreaterThan(0);
      for (const box of boxes) {
        expect(box.width, `${box.text} on ${target} has a box`).toBeGreaterThan(0);
        expect(box.left, `${box.text} on ${target} at ${size.name}`).toBeGreaterThanOrEqual(0);
        expect(box.right, `${box.text} on ${target} at ${size.name}`).toBeLessThanOrEqual(size.width);
      }

      for (const theme of ["dark", "light"]) {
        await setTheme(page, theme);
        // The links ease between theme colours, so the faintest one is polled
        // until it settles instead of being read mid-transition.
        await expect
          .poll(
            async () => {
              const ratios = await page.evaluate(CONTRAST, "nav[data-sub-nav] a");
              return Math.min(...ratios.map(({ ratio }) => ratio));
            },
            { message: `the faintest sub-nav link on ${target} in ${theme} at ${size.name}`, timeout: 5_000 }
          )
          .toBeGreaterThanOrEqual(LEGIBLE);
        await shot(page, `admin${target.replace(/\//g, "-")}-${size.name}-${theme}`);
      }
    }
  }
});

test("the admin sidebar names the two dashboards apart", async ({ page }) => {
  await page.goto("/admin/links");
  const main = page.locator("div.max-w-5xl");
  await expect(main.locator("a[href='/admin/dashboard']")).toContainText("Admin dashboard");

  await page.goto("/links");
  await expect(page.locator("div.max-w-5xl a[href='/dashboard']")).toContainText("Studio dashboard");
});
