const { test, expect } = require("@playwright/test");
const { CONTRAST } = require("./contrast");

// [e2e] The admin sidebar's first section is the main areas, and the Basement
// (/admin/basement) is the page of links the rest live on. A moved page stays one
// click away, at its old address, and the page holds at phone width in both themes.
const MOVED = [
  { href: "/admin/schema", label: "Schema", desc: "DB schema browser" },
  { href: "/admin/emails", label: "Emails", desc: "Transactional emails" },
  { href: "/admin/link_preview", label: "Link preview", desc: "Default title" },
  { href: "/assets", label: "Assets", desc: "Object store" },
  { href: "/stack", label: "Stack", desc: "tier and software" },
  { href: "/credentials", label: "Credentials", desc: "vault icons" },
  { href: "/broadcasts", label: "Broadcasts", desc: "Compose, send" },
  { href: "/contacts", label: "Contacts", desc: "mailing list" },
  { href: "/broadcasts/analytics", label: "Email analytics", desc: "Delivery, opens" },
  { href: "/error_logs", label: "Error logs", desc: "Captured errors" },
  { href: "/admin/tiktok", label: "TikTok connection", desc: "Connected account" },
  { href: "/admin/google", label: "Google connection", desc: "Calendar" },
  { href: "/admin/fathom", label: "Fathom connection", desc: "Meeting notes" },
  { href: "/admin/egnyte", label: "Egnyte connection", desc: "Document store" },
  { href: "/admin/quickbooks", label: "QuickBooks connection", desc: "Company info" },
  { href: "/admin/agent_messages", label: "Agent inbox", desc: "Messages to agents" },
  { href: "/admin/report_destinations", label: "Report destinations", desc: "Discord channel" },
  { href: "/admin/csp_reports", label: "CSP reports", desc: "Content-Security-Policy" },
  { href: "/teams", label: "Teams", desc: "All teams" },
  { href: "/people", label: "People", desc: "Players + staff" },
  { href: "/builders", label: "Builders", desc: "commit pace" },
  { href: "/docs", label: "Docs", desc: "Documentation" },
  { href: "/admin/ai_builder_multiple", label: "AI Builder Multiple", desc: "commit pace backtest" },
  { href: "/news/workflow", label: "News workflow", desc: "Intake" },
  { href: "/people/merge", label: "Merge people", desc: "Resolve duplicate" },
  { href: "/people/duplicates", label: "Duplicates", desc: "Duplicate candidates" },
  { href: "/news", label: "News", desc: "News pipeline" },
  { href: "/contents", label: "Content", desc: "Content pipeline" },
  { href: "/model_pipeline", label: "Models", desc: "Character model" },
  { href: "/body-archetypes", label: "Body archetypes", desc: "Body builds" },
  { href: "/videos", label: "Videos", desc: "digested video" },
  { href: "/alt_videos", label: "Alt videos", desc: "recast version" },
  { href: "/nfl", label: "NFL Hub", desc: "Rankings" },
  { href: "/games/2026", label: "2026 Season", desc: "Schedule" },
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

test("the sidebar reads Dashboard, DevOps, Design, Branding Kits, App Requests, Books, Activities, Basement and takes you to the Basement", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto("/dashboard");
  await page.waitForFunction(() => window.Alpine && Alpine.store("sidebars"));
  await page.locator("button[data-link-sidebar-trigger]:visible").first().click();

  const sidebar = page.locator("#studio-link-sidebar");
  await expect(sidebar).toBeVisible();
  for (const [href, word] of [
    ["/admin/dashboard", "Dashboard"],
    ["/devops", "DevOps"],
    ["/admin/style", "Design"],
    ["/logos", "Branding Kits"],
    ["/build/requests", "App Requests"],
    ["/books", "Books"],
    ["/agents/activities", "Activities"],
    ["/admin/basement", "Basement"],
  ]) {
    await expect(sidebar.locator(`a[href='${href}']`)).toContainText(word);
  }
  for (const { href } of MOVED) await expect(sidebar.locator(`a[href='${href}']`)).toHaveCount(0);
  // Dropped from every list (Alex McRitchie, 2026-11-04); the admin dashboard links the last three.
  for (const href of ["/dashboard", "/applications", "/agents", "/devops/tasks"]) {
    await expect(sidebar.locator(`a[href='${href}']`)).toHaveCount(0);
  }
  for (const [href, word] of [
    ["/build", "Build"],
    ["/chat", "Chat"],
    ["/websites", "Portfolio"],
    ["/packages", "Packages"],
    ["/integrations", "Integrations"],
  ]) {
    await expect(sidebar.locator(`a[href='${href}']`)).toContainText(word);
  }
  await expect(sidebar.locator("a", { hasText: /App Builder/ })).toHaveCount(0);
  // Moved with NFL Hub and 2026 Season, which MOVED holds (Alex McRitchie, 2026-11-04).
  await expect(sidebar.locator("a", { hasText: /Turf Monster|McRitchie Industries/ })).toHaveCount(0);

  await sidebar.locator("a[href='/admin/basement']").click();
  await expect(page).toHaveURL("/admin/basement");
  await expect(page.locator("[data-link-hub] a[href='/assets']")).toBeVisible();
  await expect(page.locator("[data-link-hub] a[href='/logos']")).toHaveCount(0);
  await expect(page.locator("[data-link-hub] a[target='_blank']", { hasText: "Turf Monster" })).toBeVisible();
  await expect(page.locator("[data-link-hub] a[target='_blank']", { hasText: "McRitchie Industries" })).toBeVisible();
  await expect(page.locator("[data-test='basement-geo']")).toContainText("Geo");
});

test("a moved page still opens from its old address, one click from the Basement", async ({ page }) => {
  await page.goto("/admin/basement");
  await page.locator("[data-link-hub] a[href='/assets']").click();
  await expect(page).toHaveURL("/assets");
  await expect(page.getByRole("heading", { level: 1 }).first()).toBeVisible();
});
