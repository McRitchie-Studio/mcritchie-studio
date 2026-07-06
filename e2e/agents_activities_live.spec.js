const { test, expect } = require("@playwright/test");

// /agents/activities live websocket updates (ActivitiesBroadcaster). The page subscribes
// via turbo_stream_from "agents_activities"; an activity/action created or updated through
// the API fires a REAL ActionCable broadcast (async adapter under Playwright) that patches
// the already-open table with NO page reload. Additive — new rows just appear.

test("a new activity streams into the feed live, then a close updates it in place", async ({ page }) => {
  const pageErrors = [];
  page.on("pageerror", (err) => pageErrors.push(String(err)));
  page.on("console", (msg) => { if (msg.type() === "error") pageErrors.push(msg.text()); });

  await page.goto("/agents/activities");
  const token = await page.getAttribute("meta[name='e2e-api-token']", "content");
  const session = `e2e-live-${Date.now()}`;
  const auth = { Authorization: `Bearer ${token}`, "Content-Type": "application/json" };

  // CREATE → the new activity tbody inserts at the top of the feed, live.
  const created = await page.request.post("/api/v1/agent_activities", {
    headers: auth,
    data: { session_id: session, category: "Explore", reason: "live insert via websocket" },
  });
  expect(created.ok()).toBeTruthy();

  await expect(
    page.locator("[data-test='aa-activity-goal']", { hasText: "live insert via websocket" })
  ).toBeVisible({ timeout: 10_000 });

  // CLOSE (an UPDATE) → the same activity's row is replaced in place with its outcome, live.
  const closed = await page.request.post("/api/v1/agent_activities/close", {
    headers: auth,
    data: { session_id: session, outcome: "closed live via websocket" },
  });
  expect(closed.ok()).toBeTruthy();

  await expect(
    page.locator("[data-test='aa-activity-result']", { hasText: "closed live via websocket" })
  ).toBeVisible({ timeout: 10_000 });

  // …with no uncaught error from the live-stream / flash handler.
  expect(pageErrors, pageErrors.join("\n")).toHaveLength(0);
});

test("a new action streams into its activity's drill-down live", async ({ page }) => {
  const pageErrors = [];
  page.on("pageerror", (err) => pageErrors.push(String(err)));
  page.on("console", (msg) => { if (msg.type() === "error") pageErrors.push(msg.text()); });

  await page.goto("/agents/activities");
  const token = await page.getAttribute("meta[name='e2e-api-token']", "content");
  const session = `e2e-action-${Date.now()}`;
  const auth = { Authorization: `Bearer ${token}`, "Content-Type": "application/json" };

  // Open an activity so the action has a parent tbody on the page.
  const created = await page.request.post("/api/v1/agent_activities", {
    headers: auth,
    data: { session_id: session, category: "Edit", reason: "activity for a live action" },
  });
  expect(created.ok()).toBeTruthy();
  await expect(
    page.locator("[data-test='aa-activity-goal']", { hasText: "activity for a live action" })
  ).toBeVisible({ timeout: 10_000 });

  // Capture a raw action for that session — it attributes to the open activity and
  // appends into its drill-down, live.
  const action = await page.request.post("/api/v1/agent_actions", {
    headers: auth,
    data: { session_id: session, kind: "grep", outcome: "ok", actor: "agent",
            event_slug: "a live-streamed action", summary: "a live-streamed action row" },
  });
  expect(action.ok()).toBeTruthy();

  await expect(
    page.locator("tr[data-test='aa-action'] [data-test='aa-action-summary']", { hasText: "a live-streamed action row" })
  ).toHaveCount(1, { timeout: 10_000 });

  expect(pageErrors, pageErrors.join("\n")).toHaveLength(0);
});
