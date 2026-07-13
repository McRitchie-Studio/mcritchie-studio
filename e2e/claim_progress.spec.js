const { test, expect } = require("@playwright/test");

// [e2e] The claim chip on the board — the happy path for "liveness is not progress".
//
// A build claim's pulsing dot means only that a TERMINAL IS PAINTING: bin/statusline
// renews the lease every ~5s, so it stays green straight through a wedged agent. On
// 2026-07-13 that green was read as progress for 35 minutes while nothing landed.
// The chip states the second, independent fact — what the task last PRODUCED — so a
// reader (or a conductor deciding whether to steal a desk) judges on evidence.
//
// Read-only against two seeded fixtures, both holding a LIVE claim:
//   e2e-quiet-claim-demo   — no durable artifact in 5h  => quiet (amber)
//   e2e-working-claim-demo — cert gate open right now    => working (muted)
//
// Nothing here reclaims anything: both desks are still HELD. The chip is
// informational, and a healthy long build must never wear the quiet styling.
test("the board states a claim's progress, not just its liveness", async ({ page }) => {
  const res = await page.goto("/tasks");
  expect(res.ok()).toBe(true);

  // A held desk that has landed nothing in hours says so, in words, in amber.
  const quietCard = page.locator("#card-e2e-quiet-claim-demo");
  await expect(quietCard).toBeVisible();

  const quietChip = quietCard.locator("[data-test='task-card-claim-progress']");
  await expect(quietChip).toBeVisible();
  await expect(quietChip).toHaveAttribute("data-progress-quiet", "true");
  await expect(quietChip).toContainText("progress 5.0h ago");
  await expect(quietChip).toContainText("cert started");
  await expect(quietChip).toHaveClass(/text-amber-300/);

  // The desk is still held — a quiet chip is a report, never a reclaim.
  await expect(quietCard).toBeVisible();

  // A healthy long build (cert running) shows its progress WITHOUT the alarm.
  const workingCard = page.locator("#card-e2e-working-claim-demo");
  await expect(workingCard).toBeVisible();

  const workingChip = workingCard.locator("[data-test='task-card-claim-progress']");
  await expect(workingChip).toHaveAttribute("data-progress-quiet", "false");
  await expect(workingChip).toContainText("g1_cert running");
  await expect(workingChip).not.toHaveClass(/text-amber-300/);
});
