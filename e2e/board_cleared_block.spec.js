const { test, expect } = require("@playwright/test");

// [e2e] The cleared-block re-review state on the board: a task whose QA block was
// resolved and is back in `submitted` renders with the amber tone + RE-REVIEW badge
// (Task#block_state => :cleared) — not the red UNRESOLVED tone. Read-only against
// the seeded `e2e-cleared-block-demo` fixture.
test("a cleared block renders the amber re-review card", async ({ page }) => {
  const res = await page.goto("/tasks");
  expect(res.ok()).toBe(true);

  const card = page.locator("#card-e2e-cleared-block-demo");
  await expect(card).toBeVisible();

  // Amber "look again" tone, not the red blocked tone.
  await expect(card).toHaveClass(/bg-amber-50/);
  await expect(card).not.toHaveClass(/bg-red-50/);

  // The RE-REVIEW badge is present; the red UNRESOLVED QA badge is not.
  await expect(card.locator("[data-test='cleared-feedback']")).toHaveText("RE-REVIEW");
  await expect(card.locator("[data-test='unresolved-feedback']")).toHaveCount(0);
});
