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

  test("devops routes are removed @qa-readonly", async ({ request }) => {
    const response = await request.get("/devops");
    expect(response.status()).toBe(404);

    const cycle = await request.get("/devops/cycle");
    expect(cycle.status()).toBe(404);
  });
});
