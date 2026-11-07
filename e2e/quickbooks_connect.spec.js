// [e2e] The QuickBooks Online connection, as an admin meets it: on
// /integrations the QuickBooks card (in the Connect group) carries Connect
// QuickBooks; connecting comes back to /integrations connected to the company
// CompanyInfo names, and /admin/quickbooks proves the read: the company and
// this year's profit and loss to date, with its net income. Loading the page
// twice proves the refresh token rotated: the stand-in honours only the last
// refresh token it issued, so a refresh that did not store its new token would
// fail the second load. Disconnect revokes at the stand-in and deletes the row.
//
// WHAT THIS DOES NOT PROVE. Nothing here reaches Intuit: the lane's stand-in
// (config/initializers/quickbooks_connect_stand_in.rb) answers for Intuit's
// sign-in page, its token and revoke endpoints and the reads. The callback,
// the code exchange, refresh and revoke code, the stored QuickbooksConnection
// and the pages are real. The real request shapes are pinned in
// test/services/quickbooks/.
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

test("admin connects QuickBooks with the stand-in, reads the profit and loss, then disconnects", async ({ page }) => {
  page.on("dialog", (dialog) => dialog.accept());
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/integrations");
  const card = page.locator("[data-test='integration-group'][data-group='connect'] [data-test='integration-entry'][data-entry='quickbooks']");
  const slot = card.locator("[data-test='entry-action'] [data-test='quickbooks-connection']");
  await expect(slot).toHaveAttribute("data-state", "none");
  await expect(card.locator("[data-test='entry-cta']")).toHaveCount(0);

  await slot.getByRole("link", { name: "Connect QuickBooks" }).click();
  await expect(page).toHaveURL(/\/integrations$/);
  await expect(page.getByText("QuickBooks connected: Stand-in Company (sandbox).")).toBeVisible();
  await expect(slot).toHaveAttribute("data-state", "connected");
  await expect(slot.locator("[data-test='quickbooks-company']")).toHaveText(/Connected to\s+Stand-in Company\s+\(sandbox\)/);
  expect(await page.content()).not.toMatch(/stand-in-(refresh|access)|9130000000000001/);

  const section = page.locator("[data-test='quickbooks-section']");
  for (const load of [1, 2]) {
    await page.goto("/admin/quickbooks");
    await expect(section, `load ${load}`).toHaveAttribute("data-state", "connected");
    await expect(section).toHaveAttribute("data-environment", "sandbox");
    await expect(section.locator("[data-field='company-info']")).toContainText("Stand-in Company");
    await expect(section.locator("[data-test='quickbooks-read']")).toHaveAttribute("data-sections", "3");
    await expect(section.locator("[data-field='net-income']")).toHaveText("600.00 USD");
    await expect(section.locator("[data-field='refreshed']")).toBeVisible();
    expect(await page.content()).not.toMatch(/stand-in-(refresh|access)|9130000000000001/);
  }

  await section.getByRole("button", { name: "Disconnect" }).click();
  await expect(page.getByText("Intuit revoked the grant and the stored token was deleted here.", { exact: false })).toBeVisible();
  await expect(section).toHaveAttribute("data-state", "none");
  await expect(page.getByRole("link", { name: "Connect QuickBooks" })).toBeVisible();

  await page.goto("/integrations");
  await expect(slot).toHaveAttribute("data-state", "none");
});
