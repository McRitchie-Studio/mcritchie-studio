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

test("a new action streams into its activity's drill-down live @quarantine", async ({ page }) => {
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
  // streams into its drill-down, live.
  const first = await page.request.post("/api/v1/agent_actions", {
    headers: auth,
    data: { session_id: session, kind: "grep", outcome: "ok", actor: "agent",
            event_slug: "older action", summary: "an OLDER live action" },
  });
  expect(first.ok()).toBeTruthy();
  await expect(
    page.locator("tr[data-test='aa-action'] [data-test='aa-action-summary']", { hasText: "an OLDER live action" })
  ).toHaveCount(1, { timeout: 10_000 });

  // A SECOND (newer) action must insert at the TOP of the drill-down, not the bottom.
  const second = await page.request.post("/api/v1/agent_actions", {
    headers: auth,
    data: { session_id: session, kind: "bash", outcome: "ok", actor: "agent",
            event_slug: "newer action", summary: "a NEWER live action" },
  });
  expect(second.ok()).toBeTruthy();
  await expect(
    page.locator("tr[data-test='aa-action'] [data-test='aa-action-summary']", { hasText: "a NEWER live action" })
  ).toHaveCount(1, { timeout: 10_000 });

  // Newest-first: the second action's row comes BEFORE the first in DOM order (they sit
  // adjacent in the same activity tbody, so full-list indices compare correctly).
  const summaries = await page.locator("tr[data-test='aa-action'] [data-test='aa-action-summary']").allInnerTexts();
  const newerIdx = summaries.findIndex((t) => t.includes("a NEWER live action"));
  const olderIdx = summaries.findIndex((t) => t.includes("an OLDER live action"));
  expect(newerIdx).toBeGreaterThanOrEqual(0);
  expect(olderIdx).toBeGreaterThanOrEqual(0);
  expect(newerIdx).toBeLessThan(olderIdx);

  expect(pageErrors, pageErrors.join("\n")).toHaveLength(0);
});

test("activity rows render measured close-diff usage instead of parent action fallback", async ({ page }) => {
  await page.goto("/agents/activities");
  const token = await page.getAttribute("meta[name='e2e-api-token']", "content");
  const session = `e2e-activity-usage-${Date.now()}`;
  const auth = { Authorization: `Bearer ${token}`, "Content-Type": "application/json" };

  const created = await page.request.post("/api/v1/agent_activities", {
    headers: auth,
    data: { session_id: session, category: "Verify", reason: "review with measured usage", agent: "shannon" },
  });
  expect(created.ok()).toBeTruthy();

  const noisyParentAction = await page.request.post("/api/v1/agent_actions", {
    headers: auth,
    data: { session_id: session, kind: "delegate", outcome: "ok", actor: "agent",
            summary: "summon primary review: shannon", model: "claude-opus-4-8",
            tokens_in: 6200, tokens_out: 383, source_turn_uuid: "parent-turn" },
  });
  expect(noisyParentAction.ok()).toBeTruthy();

  const closed = await page.request.post("/api/v1/agent_activities/close", {
    headers: auth,
    data: { session_id: session, agent: "shannon", outcome: "approved with own usage",
            model: "claude-opus-4-8", tokens_in: 9500, tokens_out: 610,
            cache_read_tokens: 120000, cost: "0.2579" },
  });
  expect(closed.ok()).toBeTruthy();

  await page.goto(`/agents/activities?sessions=${session}`);
  const activityRow = page.locator("tr.aa-arow", { hasText: "review with measured usage" }).first();
  await expect(activityRow.locator("[data-test='aa-activity-cost']")).toHaveText("$0.2579");
  await expect(activityRow.locator(".aa-cost-tok")).toHaveText("9.5k/610");
  await expect(activityRow.locator("[data-test='aa-activity-cost']")).not.toHaveText("$0.0705");
  await expect(activityRow.locator(".aa-cost-tok")).not.toHaveText("6.2k/383");
});
