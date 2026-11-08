// [e2e] An admin connects a Microsoft 365 tenant from the /integrations card,
// reads it on /admin/msgraph (users, Teams, root site, drives) on two loads,
// and disconnects. No page shows the tenant id. Nothing reaches Microsoft: the
// lane's stand-in (config/initializers/msgraph_connect_stand_in.rb) answers
// consent, tokens and reads; the callback, token cache, row and pages are real.
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

const TENANT = /00000000-0000-0000-0000-00000000c0de/i;

test("admin connects a Microsoft 365 tenant with the stand-in, reads it, and disconnects", async ({ page }) => {
  page.on("dialog", (dialog) => dialog.accept());
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/integrations");
  const card = page.locator("[data-test='integration-group'][data-group='connect'] [data-test='integration-entry'][data-entry='microsoft_365']");
  const slot = card.locator("[data-test='entry-action'] [data-test='msgraph-connection']");
  await expect(card.locator("[data-test='coming-soon']")).toBeVisible();
  await expect(slot).toHaveAttribute("data-state", "none");
  await expect(card.locator("[data-test='entry-cta']")).toHaveCount(0);

  await slot.getByRole("link", { name: "Connect Microsoft 365" }).click();
  await expect(page).toHaveURL(/\/integrations$/);
  await expect(page.getByText("Microsoft 365 connected for Stand-in Tenant.")).toBeVisible();
  await expect(slot).toHaveAttribute("data-state", "connected");
  await expect(slot.locator("[data-test='msgraph-tenants']")).toHaveText(/Connected:\s+Stand-in Tenant/);
  expect(await page.content()).not.toMatch(TENANT);

  const section = page.locator("[data-test='msgraph-section']");
  for (const load of [1, 2]) {
    await page.goto("/admin/msgraph");
    await expect(section, `load ${load}`).toHaveAttribute("data-state", "connected");
    await expect(section.locator("[data-field='display-name']")).toHaveText("Stand-in Tenant");
    await expect(section.locator("[data-field='users']")).toHaveAttribute("data-count", "3");
    await expect(section.locator("[data-field='users']")).toHaveAttribute("data-more", "true");
    await expect(section.locator("[data-field='teams']")).toHaveAttribute("data-count", "2");
    await expect(section.locator("[data-field='site']")).toHaveText("Communication site");
    await expect(section.locator("[data-field='drives']")).toHaveText("Documents and Drawings");
    const html = await page.content();
    expect(html).not.toMatch(TENANT);
    expect(html).not.toMatch(/stand-in-graph-/);
  }

  await section.getByRole("button", { name: "Disconnect" }).click();
  await expect(page.getByText("Microsoft 365 disconnected for Stand-in Tenant", { exact: false })).toBeVisible();
  await expect(section).toHaveAttribute("data-state", "none");
  await expect(page.locator("[data-test='msgraph-connect']")).toBeVisible();

  await page.goto("/integrations");
  await expect(slot).toHaveAttribute("data-state", "none");
});
