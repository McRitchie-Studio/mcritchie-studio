const { test, expect } = require("@playwright/test");
const { VISITOR } = require("./helpers");

// Runs against QA and PRODUCTION after a ship (bin/prod-smoke), as a visitor: the public
// pages answer, and the ops pages sit behind the admin wall
// (app/controllers/concerns/admin_wall.rb), sending a visitor to sign-in.
test.use({ storageState: VISITOR });

test.describe("QA read-only smoke @qa-readonly", () => {
  test("public routes respond to a visitor @qa-readonly", async ({ page, request }) => {
    const health = await request.get("/up");
    expect(health.status()).toBe(200);

    const root = await page.goto("/");
    expect(root.ok()).toBe(true);
    await expect(page).toHaveTitle(/McRitchie Studio/);
    await expect(page.locator("body")).toContainText("McRitchie Studio");

    const signin = await page.goto("/signin");
    expect(signin.ok()).toBe(true);
    await expect(page.locator('input[name="email"]')).toBeVisible();

    for (const path of ["/packages", "/terms", "/privacy"]) {
      const response = await page.goto(path);
      expect(response.ok(), `${path} answers a visitor`).toBe(true);
      expect(new URL(page.url()).pathname, `${path} is not walled`).toBe(path);
    }
  });

  test("the task board sends a visitor to sign-in @qa-readonly", async ({ page, request }) => {
    const tasks = await request.get("/tasks", { maxRedirects: 0 });
    expect(tasks.status()).toBe(302);
    expect(new URL(tasks.headers()["location"], "http://host").pathname).toBe("/login");

    await page.goto("/tasks");
    expect(new URL(page.url()).pathname).toMatch(/^\/(login|signin)$/);
    await expect(page.locator('input[name="email"]')).toBeVisible();
  });

  test("devops routes are removed @qa-readonly", async ({ request }) => {
    const response = await request.get("/devops");
    expect(response.status()).toBe(404);

    const cycle = await request.get("/devops/cycle");
    expect(cycle.status()).toBe(404);
  });
});
