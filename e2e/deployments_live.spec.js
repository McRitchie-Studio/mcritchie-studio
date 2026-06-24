const { test, expect } = require("@playwright/test");

// /deployments live updates (DeploymentsChannel). The seeded `live-cable-demo`
// task starts in `submitted` with a crew but NO intent — so its card shows no
// live ticker. Recording a review intent against it (as if another session began
// the review) fires a real ActionCable broadcast; the already-open board swaps the
// card IN PLACE and the in-progress ticker appears — with NO page reload.
test("the deployments board updates a card live when an intent is recorded", async ({ page }) => {
  await page.goto("/deployments");

  const card = page.locator("#card-live-cable-demo");
  await expect(card).toBeVisible();
  // No live ticker yet — no intent has been recorded.
  await expect(card.locator("[data-test='crew-live']")).toHaveCount(0);

  // Trigger the review intent via the API (test-only token rendered on the board).
  const token = await page.getAttribute("meta[name='e2e-api-token']", "content");
  const res = await page.request.post("/api/v1/tasks/live-cable-demo/intent", {
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    data: {
      to_stage: "reviewed",
      reviewers: [{ slug: "carl", weight: "heavy" }, { slug: "shannon", weight: "light" }],
      event: { source: "cli" },
    },
  });
  expect(res.ok()).toBeTruthy();

  // The board (never reloaded) receives the broadcast and replaces the card in
  // place; the in-progress review ticker now renders.
  await expect(card.locator("[data-test='crew-live']")).toHaveCount(1, { timeout: 10_000 });

  // The card stayed put in the Submitted column (an in-place update, not a move).
  await expect(page.locator("#dropzone-submitted #card-live-cable-demo")).toBeVisible();
});
