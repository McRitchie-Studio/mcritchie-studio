const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

test("admin can open the Coach model from admin models", async ({ page }) => {
  await loginWithMagicLink(page, "alex@test.com");

  await page.goto("/admin/models");
  await expect(page.getByRole("heading", { name: "Models" })).toBeVisible();

  const coachesSection = page.locator("#model-coaches");
  await expect(coachesSection).toContainText("Coaches");
  await expect(coachesSection.locator("#models-coaches-table")).toContainText("Sean McDermott");

  await coachesSection.getByRole("link", { name: "View all" }).click();
  await expect(page).toHaveURL(/\/admin\/models\/coaches$/);
  await expect(page.getByRole("heading", { name: "Coaches" })).toBeVisible();
  await expect(page.locator("#models-coaches-table")).toContainText("Buffalo Bills");
  await expect(page.locator("#models-coaches-table")).toContainText("Head Coach");
});
