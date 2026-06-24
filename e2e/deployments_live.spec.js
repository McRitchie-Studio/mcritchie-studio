const { test, expect } = require("@playwright/test");

// /deployments live updates (DeploymentsChannel). The seeded `live-cable-demo`
// task starts in `submitted` with a crew but NO intent — so its card shows no
// live ticker. Recording a review intent against it (as if another session began
// the review) fires a real ActionCable broadcast; the already-open board swaps the
// card IN PLACE and the in-progress ticker appears — with NO page reload.
test("the deployments board updates a card live when an intent is recorded", async ({ page }) => {
  // The original miss was an UNCAUGHT TypeError in the broadcast handler (a wrong
  // method name) that fired after the DOM mutation — guard against any such throw.
  const pageErrors = [];
  page.on("pageerror", (err) => pageErrors.push(String(err)));
  page.on("console", (msg) => { if (msg.type() === "error") pageErrors.push(msg.text()); });

  await page.goto("/deployments");

  const card = page.locator("#card-live-cable-demo");
  await expect(card).toBeVisible();
  await expect(card.locator("[data-test='crew-live']")).toHaveCount(0);

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
  await expect(page.locator("#dropzone-submitted #card-live-cable-demo")).toBeVisible();

  // …with no uncaught error from the broadcast handler.
  expect(pageErrors, pageErrors.join("\n")).toHaveLength(0);
});

// A live STAGE CHANGE moves the card to its new column AND updates the per-column
// count badges — the regression guard for the updateCounts() call in
// applyLiveUpdate (a wrong method name left the badges stale on every broadcast).
test("a live stage change FLIPs the card to its new column and updates the count badges", async ({ page }) => {
  await page.goto("/deployments");

  await expect(page.locator("#dropzone-submitted #card-live-cable-move-demo")).toBeVisible();

  const reviewedBadge = page.locator("[data-stage-count='reviewed']");
  const before = Number(((await reviewedBadge.textContent()) || "0").trim());

  // Move submitted→reviewed via the API → a real stage_change broadcast.
  const token = await page.getAttribute("meta[name='e2e-api-token']", "content");
  const res = await page.request.patch("/api/v1/tasks/live-cable-move-demo", {
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    data: { stage: "reviewed", event: { source: "cli", actor: "avi" } },
  });
  expect(res.ok()).toBeTruthy();

  // The board (no reload) FLIPs the card into the Reviewed column…
  await expect(page.locator("#dropzone-reviewed #card-live-cable-move-demo")).toBeVisible({ timeout: 10_000 });
  // …and the Reviewed count badge updates (a stale badge means the handler threw).
  await expect(reviewedBadge).toHaveText(String(before + 1));
});
