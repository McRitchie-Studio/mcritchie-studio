const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

// The drilldown cap: an over-cap activity (55 seeded actions) renders only the
// 50 newest turn rows plus an omitted-tail affordance carrying the TRUE count.
// The feed is auth-gated (combinatorial-crawl trap), so sign in first.
//
// What the feed actually renders per turn row is `summary || event_slug`
// ("Run suite slice N") — the seeded result_slug never appears here. Substring
// checks on the omitted tail are a trap ("Run suite slice 15" contains
// "Run suite slice 1"), so the window is pinned with exact per-row text.
test("over-cap activity drilldown names its omitted tail", async ({ page }) => {
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/agents/activities?sessions=e2e-drilldown-cap-0001");

  // The activity row stays honest: the TRUE count, not the capped row count.
  const body = page.locator("body");
  await expect(body).toContainText("sweep the full suite");
  await expect(body).toContainText("55 actions");

  // The omitted-tail row names the remainder and the window size.
  await expect(body).toContainText("5 more actions omitted");
  await expect(body).toContainText("showing the newest 50");

  // Exactly 50 turn rows, newest-first: slice 55 leads, slice 6 closes the
  // window, and the 5 oldest (slices 1-5) never reach the DOM.
  const summaries = page.locator('[data-test="aa-turn-summary"]');
  await expect(summaries).toHaveCount(50);
  await expect(summaries.first()).toHaveText("Run suite slice 55");
  await expect(summaries.last()).toHaveText("Run suite slice 6");
  await expect(page.getByText("Run suite slice 5", { exact: true })).toHaveCount(0);
});
