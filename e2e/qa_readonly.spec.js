const { test, expect } = require("@playwright/test");

test.describe("QA read-only smoke @qa-readonly", () => {
  test("public routes and the task board respond @qa-readonly", async ({ page, request }) => {
    const health = await request.get("/up");
    expect(health.status()).toBe(200);

    const root = await page.goto("/");
    expect(root.ok()).toBe(true);
    await expect(page).toHaveTitle(/McRitchie Studio/);
    await expect(page.locator("body")).toContainText("McRitchie Studio");

    const signin = await page.goto("/signin");
    expect(signin.ok()).toBe(true);
    await expect(page.locator('input[name="email"]')).toBeVisible();

    const tasks = await page.goto("/tasks");
    expect(tasks.ok()).toBe(true);
    await expect(page.locator("body")).toContainText("Tasks");
  });

  test("devops route stays auth-gated @qa-readonly", async ({ page }) => {
    const response = await page.goto("/devops");
    expect(response.ok()).toBe(true);
    await expect(page).toHaveURL(/\/(login|signin)$/);
    await expect(page.locator('input[name="email"]')).toBeVisible();
  });
});
