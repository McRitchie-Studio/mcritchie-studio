const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

test("admin follows the dashboard's Users card, then opens the Coach model", async ({ page }) => {
  await loginWithMagicLink(page, "alex@test.com");

  await page.goto("/admin/dashboard");
  await page.locator("[data-test='stat-card-users']").click();
  await expect(page).toHaveURL(/\/admin\/models\/users$/);
  await expect(page.locator("#models-users-table")).toBeVisible();

  await page.goto("/admin/models/coaches");
  await expect(page.locator("#models-coaches-table")).toContainText("Buffalo Bills");
  await expect(page.locator("#models-coaches-table")).toContainText("Head Coach");
});
