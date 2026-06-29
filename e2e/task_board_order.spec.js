const { test, expect } = require("@playwright/test");

async function createTask(page, token, attrs) {
  const res = await page.request.post("/api/v1/tasks", {
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    data: attrs,
  });
  expect(res.ok(), await res.text()).toBeTruthy();
}

test("reactivated blocked work renders above still-blocked cards in Building", async ({ page }) => {
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
