const { test, expect } = require("@playwright/test");

// Happy path: the seeded `timeline-demo` task walked the full lifecycle, so its
// show page renders the Stage Timeline with per-transition badges, a measured
// duration, and the agent-reported model cost.
test("task show page renders the stage timeline with transitions, duration, and cost", async ({ page }) => {
  await page.goto("/tasks/timeline-demo");

  const timeline = page.locator("[data-test='stage-timeline']");
  await expect(timeline).toBeVisible();
  await expect(timeline).toContainText("Stage Timeline");

  // Transition badges across the lifecycle (Created → Designed → Building → Submitted → Reviewed)
  await expect(timeline).toContainText("Created");
  await expect(timeline).toContainText("Designed");
  await expect(timeline).toContainText("Building");
  await expect(timeline).toContainText("Submitted");
  await expect(timeline).toContainText("Reviewed");

  // Measured duration (server-owned) and reported usage (agent-supplied)
  await expect(timeline).toContainText("in Building");
  await expect(timeline).toContainText("claude-opus-4-8");
  await expect(timeline).toContainText("$5.40");
});
