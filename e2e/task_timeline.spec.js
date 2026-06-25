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

  // Uniform metric block: measured duration (server-owned) + reported usage (agent-supplied)
  await expect(timeline).toContainText("Duration");
  await expect(timeline).toContainText("Tokens");
  await expect(timeline).toContainText("claude-opus-4-8");
  await expect(timeline).toContainText("$5.40");
});

// Agentic intent: the seeded `intent-demo` task is submitted with an OPEN review
// intent, so the consolidated timeline shows a LIVE in-progress block — both
// seniors on it, ticking — before the →reviewed transition lands.
test("task timeline shows a live in-progress block for an open review intent", async ({ page }) => {
  await page.goto("/tasks/intent-demo");

  const timeline = page.locator("[data-test='stage-timeline']");
  await expect(timeline).toBeVisible();

  // The live in-progress block + its ticking counter render
  await expect(page.locator("[data-test='timeline-inprogress']")).toBeVisible();
  const live = page.locator("[data-test='timeline-live']");
  await expect(live).toBeVisible();

  // Both senior reviewers are named on the live block, with the heavy/light split
  const block = page.locator("[data-test='timeline-block'][data-in-progress='true']");
  await expect(block).toContainText("Carl");
  await expect(block).toContainText("Shannon");
  await expect(block).toContainText("heavy");

  // The ticker is a real elapsed value (e.g. "0s"/"3m"), not the "…" placeholder
  await expect(live).not.toHaveText("…");
});
