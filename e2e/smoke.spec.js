const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

// ---------------------------------------------------------------------------
// Page loads
// ---------------------------------------------------------------------------

test("landing page loads", async ({ page }) => {
  await page.goto("/");
  await expect(page.locator("body")).toContainText("McRitchie Studio");
  await expect(page.locator("body")).toContainText("Software For");
  await expect(page.locator("body")).toContainText("Alex McRitchie");
});

test("dashboard loads with agent cards", async ({ page }) => {
  await page.goto("/dashboard");
  await expect(page.locator("body")).toContainText("Agents");
  await expect(page.locator("body")).toContainText("Mack");
});

test("agents page loads", async ({ page }) => {
  await page.goto("/agents");
  await expect(page.locator("body")).toContainText("Alex");
  await expect(page.locator("body")).toContainText("Mack");
});

test("agent detail loads", async ({ page }) => {
  await page.goto("/agents/alex");
  await expect(page.locator("body")).toContainText("Alex");
  await expect(page.locator("body")).toContainText("orchestrator");
});

test("tasks page loads with stage badges", async ({ page }) => {
  await page.goto("/tasks");
  await expect(page.locator("body")).toContainText("Review agent protocol");
  await expect(page.locator("body")).toContainText("Scrape odds data");
  await expect(page.locator("body")).toContainText("Deploy v2 release");
});

test("task detail loads", async ({ page }) => {
  await page.goto("/tasks");
  // Click the first task link
  await page.click("text=Review agent protocol");
  await expect(page.locator("body")).toContainText("Review agent protocol");
  await expect(page.locator("body")).toContainText("Audit inter-agent messaging");
});

test("activities page loads", async ({ page }) => {
  await page.goto("/activities");
  await expect(page.locator("body")).toContainText("Assigned scrape task to Mack");
  await expect(page.locator("body")).toContainText("Started scraping odds data");
});

test("usages page loads", async ({ page }) => {
  await page.goto("/usages");
  // Page loads without error (may be empty table)
  await expect(page.locator("body")).toBeVisible();
});

// ---------------------------------------------------------------------------
// Authentication
// ---------------------------------------------------------------------------

test("login with magic link", async ({ page }) => {
  await loginWithMagicLink(page, "alex@test.com");
  // Username should appear in header
  await expect(page.locator("body")).toContainText("Alex Test");
});

test("malformed magic link request stays on signin", async ({ page }) => {
  await page.goto("/signin");
  await page.fill('input[name="email"]', "not-an-email");
  await page.click('form:has(input[name="email"]) button[type="submit"]');
  await expect(page).toHaveURL("/signin");
});

// ---------------------------------------------------------------------------
// Navigation links
// ---------------------------------------------------------------------------

test("nav links work without errors", async ({ page }) => {
  await page.goto("/");

  await page.getByRole("link", { name: /Agents/ }).first().click();
  await expect(page).toHaveURL("/activities");

  await page.goto("/");
  await page.getByRole("link", { name: /Say Hi/ }).click();
  await expect(page).toHaveURL("/signin");
});

test("logged-in link sidebar reopens after browser back from signed-in routes", async ({ page }) => {
  await loginWithMagicLink(page, "alex@test.com");

  const routes = ["/dashboard", "/tasks", "/tasks/task-ea8541e4b5b6", "/agents"];
  const triggers = [
    "button[data-link-sidebar-trigger]",
    "button[data-username-display]",
    "button[data-profile-image-toggle]",
  ];

  for (const route of routes) {
    await page.goto(route);
    await page.waitForFunction(() => window.Alpine && Alpine.store("sidebars"));

    await page.locator("button[data-link-sidebar-trigger]").first().click();
    await expect(page.locator("#studio-link-sidebar")).toBeVisible();

    const destination = route === "/agents" ? "/tasks" : "/agents";
    await page.locator(`#studio-link-sidebar a[href="${destination}"]`).first().click();
    await expect(page).toHaveURL(destination);

    await page.goBack();
    await expect(page).toHaveURL(route);
    await page.waitForFunction(() => window.Alpine && Alpine.store("sidebars"));

    for (const trigger of triggers) {
      await page.locator(trigger).first().click();
      await expect(page.locator("#studio-link-sidebar")).toBeVisible();
      await page.keyboard.press("Escape");
      await expect(page.locator("#studio-link-sidebar")).toBeHidden();
    }
  }
});

test("logged-in sidebar logout still signs out", async ({ page }) => {
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/dashboard");
  await page.waitForFunction(() => window.Alpine && Alpine.store("sidebars"));

  await page.locator("button[data-link-sidebar-trigger]").first().click();
  await expect(page.locator("#studio-link-sidebar")).toBeVisible();
  await page.locator('#studio-link-sidebar a[href="/logout"]').click();

  await expect(page).toHaveURL("/signin");
  await expect(page.locator("body")).toContainText("Say Hi");
});

// ---------------------------------------------------------------------------
// Theme toggle
// ---------------------------------------------------------------------------

test("theme toggle switches dark/light and updates localStorage", async ({ page }) => {
  await page.goto("/");

  // Wait for Alpine.js to initialize (loaded via defer)
  await page.waitForFunction(() => window.Alpine, null, { timeout: 10_000 });

  // Default is dark
  const html = page.locator("html");
  await expect(html).toHaveClass(/dark/);

  // Click theme toggle button
  await page.click('button[title="Toggle theme"]');

  // Should switch to light (dark class removed)
  await expect(html).not.toHaveClass(/dark/);

  // localStorage should be updated
  const theme = await page.evaluate(() => localStorage.getItem("theme"));
  expect(theme).toBe("light");
});

test("theme persists on reload", async ({ page }) => {
  await page.goto("/");
  await page.waitForFunction(() => window.Alpine, null, { timeout: 10_000 });

  // Toggle to light
  await page.click('button[title="Toggle theme"]');
  await expect(page.locator("html")).not.toHaveClass(/dark/);

  // Reload
  await page.reload();

  // Should still be light
  await expect(page.locator("html")).not.toHaveClass(/dark/);
  const theme = await page.evaluate(() => localStorage.getItem("theme"));
  expect(theme).toBe("light");
});

test("dark mode is default for fresh context", async ({ context }) => {
  // Fresh context has no localStorage
  const page = await context.newPage();
  await page.goto("/");
  await expect(page.locator("html")).toHaveClass(/dark/);
});
