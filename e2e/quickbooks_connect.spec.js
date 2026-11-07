// [e2e] An admin connects QuickBooks from the /integrations card, reads the
// company and its profit and loss on /admin/quickbooks twice (the stand-in
// honours only its last refresh token, so a lost rotation fails load two), and
// disconnects. Nothing reaches Intuit: config/initializers/
// quickbooks_connect_stand_in.rb answers sign-in, tokens, revoke and reads.
// The callback, exchange, refresh, revoke and pages are real; request shapes
// are pinned in test/services/quickbooks/.
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
