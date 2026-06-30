const { test, expect } = require("@playwright/test");

// [e2e] The T5 feedback loop on the read-only heartbeat: open an action's grading
// drawer, write Alex's grade, bank it, and confirm it surfaces in the Insight Bank —
// plus the inline radios persisting a disposition without ever opening the drawer.
test("grade an action, bank it, and see it in the Insight Bank", async ({ page }) => {
  await page.goto("/alex/heartbeat");
  const drawer = page.locator("aside[data-test='heartbeat-drawer']");

  // Open the grading drawer for the first action by clicking its event cell.
  await page.locator("tr[data-test='heartbeat-row'] .hb-slug").first().click();
  await expect(drawer).toHaveClass(/hb-drawer-open/);

  // The Alex grade editor is the first feedback block in the lazy-loaded drawer body.
  const alexForm = drawer.locator("form.hb-fbblock").first();
  await expect(alexForm.locator("input[name='slug']")).toBeVisible();

  const lesson = "Bank this lesson from e2e";
  await alexForm.locator("input[name='slug']").fill(lesson);
  await alexForm.locator(".hb-disptoggle button", { hasText: "Good" }).click();
  await alexForm.locator("button[value='bank']").click();

  // The inline cell for that row now shows the banked marker (turbo_stream swap).
  const firstRow = page.locator("tr[data-test='heartbeat-row']").first();
  await expect(firstRow.locator("td.hb-fbcell-alex .hb-bankmark")).toBeVisible();

  // And the lesson is curated into the Insight Bank.
  await page.goto("/alex/insights");
  await expect(page.locator("[data-test='insight-bank']")).toBeVisible();
  await expect(page.locator("[data-test='insight']", { hasText: lesson })).toBeVisible();
});

test("inline radios persist a disposition without opening the drawer", async ({ page }) => {
  await page.goto("/alex/heartbeat");
  const firstRow = page.locator("tr[data-test='heartbeat-row']").first();

  // Pick the Good radio in the Alex feedback cell; the cell re-renders with the
  // on-good highlight once the turbo_stream lands.
  await firstRow.locator("td.hb-fbcell-alex input[type=radio][value='good']").check();
  await expect(firstRow.locator("td.hb-fbcell-alex label.hb-rb.on-good")).toBeVisible();

  // The drawer was never opened by an inline grade.
  await expect(page.locator("aside[data-test='heartbeat-drawer']")).not.toHaveClass(/hb-drawer-open/);
});
