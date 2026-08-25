const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

// Model-page protocol (v1): an admin opens the newest release's model page from
// /deployments/all, sees its JSON + copy/paste console command, then jumps to a
// random sample record.
test("admin opens a Release model page and jumps to a random sample", async ({ page }) => {
  await loginWithMagicLink(page, "alex@test.com");

  await page.goto("/deployments/all");
  await expect(page.getByRole("heading", { name: "All Deployments" })).toBeVisible();

  // The admin-only "Model" link jumps to the latest release's model page.
  await page.getByRole("link", { name: "Model", exact: true }).click();
  await expect(page).toHaveURL(/\/models\/release\/.+/);

  // v1 renders exactly two things: the console command and the record JSON.
  // Scope to the console section: the engine's link sidebar renders its own
  // <code> (the geo signpost), so a bare locator("code") is not unique.
  const consoleCode = page
    .locator("section")
    .filter({ hasText: "Rails console" })
    .locator("code");
  await expect(page.getByText("Rails console")).toBeVisible();
  await expect(consoleCode).toContainText("Release.find_by(slug:");
  await expect(page.locator("pre")).toContainText('"slug"');

  // The random-sample button lands on another (valid) Release model page.
  await page.getByRole("link", { name: /Random sample/ }).click();
  await expect(page).toHaveURL(/\/models\/release\/.+/);
  await expect(consoleCode).toContainText("Release.find_by(slug:");
  await expect(page.locator("pre")).toContainText('"slug"');
});
