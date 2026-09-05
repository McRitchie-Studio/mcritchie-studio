const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

// The [e2e] tier of /tasks/drop-hub-wallet-column. The request-level guards
// (test/integration/wallet_chips_dropped_test.rb) assert the rendered HTML; this
// one walks the actual page, because the Auth column is the one place a stale
// "wallet" pill would still look like part of the design rather than a leftover.
//
// EVERY ABSENCE HERE IS PAIRED WITH A PRESENCE. "the page has no wallet chip" is
// also what a page that never loaded says, so each assertion first proves the
// table and its Auth column really painted.
test("the admin users table shows auth chips with no wallet among them", async ({ page }) => {
  await loginWithMagicLink(page, "alex@test.com");

  await page.goto("/admin/models/users");
  await expect(page.getByRole("heading", { name: "Users" })).toBeVisible();

  const usersTable = page.locator("#models-users-table");
  await expect(usersTable).toBeVisible();
  // The control: the signed-in account is really in this table.
  await expect(usersTable).toContainText("alex@test.com");
  // The Auth column header proves the chip column itself rendered.
  await expect(page.getByRole("columnheader", { name: "Auth" })).toBeVisible();

  await expect(usersTable).not.toContainText("wallet");
  await expect(usersTable).not.toContainText("No email or wallet");
});
