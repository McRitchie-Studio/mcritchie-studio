const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

// [e2e] The prod-deploy approval gate on /deployments. The seed leaves a
// "Production Deploy" run BLOCKED at its production environment gate
// (pending_environment set). A visitor sees the amber "awaiting approval" state;
// an admin additionally gets the Approve button wired to the approve route.
test.describe("deploy approval gate", () => {
  test("a visitor sees the pending-approval state but no Approve button", async ({ page }) => {
    await page.goto("/deployments");

    const panel = page.locator("[data-test='github-actions-panel']");
    await expect(panel).toBeVisible();

    const pending = panel.locator("[data-test='github-actions-run'][data-state='pending_approval']");
    await expect(pending).toBeVisible();
    await expect(pending.locator("[data-test='github-actions-pill']")).toHaveText(/awaiting approval/i);
    await expect(pending).toContainText("Production Deploy");
    await expect(pending).toContainText("production");

    // An obvious, styled link to the GitHub run page (the card is not a whole-row anchor).
    const viewRun = pending.locator("a[data-test='github-actions-view-run']");
    await expect(viewRun).toBeVisible();
    await expect(viewRun).toHaveText(/view run on github/i);
    await expect(viewRun).toHaveAttribute("href", /\/actions\/runs\/\d+/);
    await expect(viewRun).toHaveAttribute("target", "_blank");

    // No Approve button for a signed-out visitor; the locked hint stands in.
    await expect(pending.locator("[data-test='github-actions-approve']")).toHaveCount(0);
    await expect(pending.locator("[data-test='github-actions-approve-locked']")).toBeVisible();
  });

  test("an admin sees the Approve button wired to the approve route", async ({ page }) => {
    await loginWithMagicLink(page, "alex@test.com");
    await page.goto("/deployments");

    const pending = page.locator("[data-test='github-actions-run'][data-state='pending_approval']");
    await expect(pending).toBeVisible();

    const approve = pending.locator("button[data-test='github-actions-approve']");
    await expect(approve).toBeVisible();
    await expect(approve).toHaveText(/approve/i);

    const form = pending.locator("form");
    await expect(form).toHaveAttribute("action", /\/deployments\/\d+\/approve/);
    await expect(form).toHaveAttribute("method", "post");
  });

  test("the pending row reads correctly in light mode too", async ({ page }) => {
    await page.goto("/deployments");
    const html = page.locator("html");
    await expect(html).toHaveClass(/dark/);
    await page.click('button[title="Toggle theme"]');
    await expect(html).not.toHaveClass(/dark/);

    const pending = page.locator("[data-test='github-actions-run'][data-state='pending_approval']");
    await expect(pending).toBeVisible();
    await expect(pending.locator("[data-test='github-actions-pill']")).toHaveText(/awaiting approval/i);
  });
});
