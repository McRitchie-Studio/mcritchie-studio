const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

// MUTATING spec (promotes the seeded finding into a task) — never tag @qa-readonly.
test("operator promotes a triage finding into a designed task", async ({ page }) => {
  await loginWithMagicLink(page, "alex@test.com");

  await page.goto("/triage");
  await expect(page.getByRole("heading", { name: "Triage" })).toBeVisible();
  await expect(page.locator("body")).toContainText("E2E Promotable Finding");

  const findingRow = page.locator("li", { hasText: "E2E Promotable Finding" }).first();
  await findingRow.locator('input[name="title"]').fill("E2E Promoted Finding Task");
  await findingRow.locator('select[name="kind"]').selectOption("chore");
  await findingRow.getByRole("button", { name: "Promote" }).click();

  await expect(page.locator("body")).toContainText("Promoted to task");
  await expect(page.locator("body")).toContainText("Recently resolved");
  await expect(page.locator("body")).toContainText("promoted");
});
