const { test, expect } = require("@playwright/test");

async function createTask(page, token, attrs) {
  const res = await page.request.post("/api/v1/tasks", {
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    data: attrs,
  });
  expect(res.ok(), await res.text()).toBeTruthy();
}

test("reactivated blocked work renders above still-blocked cards in Building @quarantine", async ({ page }) => {
  await page.goto("/tasks");

  const token = await page.getAttribute("meta[name='e2e-api-token']", "content");
  const suffix = Date.now();
  const blockedSlug = `e2e-stale-blocked-${suffix}`;
  const reactivatedSlug = `e2e-reactivated-${suffix}`;

  await createTask(page, token, {
    slug: blockedSlug,
    title: "E2E stale blocked order",
    stage: "blocked",
    priority: 1,
    agent_slug: "carl",
  });
  await createTask(page, token, {
    slug: reactivatedSlug,
    title: "E2E reactivated order card",
    stage: "blocked",
    priority: 1,
    agent_slug: "carl",
  });

  const move = await page.request.patch(`/api/v1/tasks/${reactivatedSlug}`, {
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    data: { stage: "building", event: { source: "cli", actor: "carl" } },
  });
  expect(move.ok(), await move.text()).toBeTruthy();

  await page.reload();

  const cardIds = await page.locator("#dropzone-building .kanban-card").evaluateAll((cards) => cards.map((card) => card.id));
  const reactivatedIndex = cardIds.indexOf(`card-${reactivatedSlug}`);
  const blockedIndex = cardIds.indexOf(`card-${blockedSlug}`);

  expect(reactivatedIndex).toBeGreaterThanOrEqual(0);
  expect(blockedIndex).toBeGreaterThanOrEqual(0);
  expect(reactivatedIndex).toBeLessThan(blockedIndex);
});

test("approval waiting work pulses, ranks first, and exposes Local Demo @quarantine", async ({ page }) => {
  await page.goto("/tasks");

  const token = await page.getAttribute("meta[name='e2e-api-token']", "content");
  const suffix = Date.now();
  const waitingSlug = `e2e-approval-waiting-${suffix}`;
  const normalSlug = `e2e-normal-building-${suffix}`;

  await createTask(page, token, {
    slug: waitingSlug,
    title: "E2E approval waiting",
    stage: "building",
    priority: 1,
    agent_slug: "carl",
    devops: {
      approval_status: "waiting",
      local_url: "http://localhost:3001/demo",
    },
  });
  await createTask(page, token, {
    slug: normalSlug,
    title: "E2E normal building",
    stage: "building",
    priority: 1,
    agent_slug: "carl",
  });

  await page.reload();

  const cardIds = await page.locator("#dropzone-building .kanban-card").evaluateAll((cards) => cards.map((card) => card.id));
  const waitingIndex = cardIds.indexOf(`card-${waitingSlug}`);
  const normalIndex = cardIds.indexOf(`card-${normalSlug}`);

  expect(waitingIndex).toBeGreaterThanOrEqual(0);
  expect(normalIndex).toBeGreaterThanOrEqual(0);
  expect(waitingIndex).toBeLessThan(normalIndex);

  const waitingCard = page.locator(`#card-${waitingSlug}`);
  await expect(waitingCard).toHaveAttribute("data-stage-glow", "approval");
  await expect(waitingCard.locator("[data-test='operator-approval-waiting']")).toHaveText("WAITING APPROVAL");
  const localDemo = waitingCard.locator("[data-test='local-demo-button']");
  await expect(localDemo).toHaveText("Local Demo");
  await expect(localDemo).toHaveAttribute("href", "http://localhost:3001/demo");
});
