const { test, expect } = require("@playwright/test");

// The Alex avenue (/alex/heartbeat) renders the agent-narrated EVENT trajectory from
// the seeded spans — each row an AtomicEvent (category · reason -> outcome) that
// drills down (Alpine) into the raw tool-calls attributed to it. The seed narrates a
// couple of closed spans, a final OPEN span ("…in progress"), plus one pre-narration
// action in the read-only "Unlabeled" group.
test("alex heartbeat renders the narrated event spans as the primary rows", async ({ page }) => {
  await page.goto("/alex/heartbeat");

  const table = page.locator("[data-test='heartbeat-event-table']");
  await expect(table).toBeVisible();

  // The seeded spans render as event rows, each with its category badge.
  const events = page.locator("[data-test='heartbeat-event']");
  expect(await events.count()).toBeGreaterThanOrEqual(2);
  await expect(table).toContainText("Explore");
  await expect(table).toContainText("Verify");
  await expect(table).toContainText("Workflow");

  // The final span is still open — it renders the in-progress placeholder.
  await expect(page.locator("[data-test='event-in-progress']").first()).toBeVisible();

  // The raw tool-calls the agent never narrated fall into the Unlabeled group.
  await expect(page.locator("[data-test='heartbeat-unlabeled']")).toBeVisible();
});

// A span is collapsed by default; expanding it (Alpine) reveals the raw actions
// attributed to it — kind + input — as read-only drill-down rows.
test("expanding a span drills down into its attributed actions", async ({ page }) => {
  await page.goto("/alex/heartbeat");

  const span = page.locator("[data-test='heartbeat-event'][data-category='Explore']");
  const firstAction = span.locator("tr[data-test='heartbeat-event-action']").first();

  // Collapsed by default — the action drill-down rows are hidden.
  await expect(firstAction).toBeHidden();

  // Expand the span; its raw tool-calls become visible, showing kind + input.
  await span.locator("tr[data-test='heartbeat-event-row']").click();
  await expect(firstAction).toBeVisible();
  await expect(firstAction).toContainText("grep");
});

// Grading is preserved: clicking a drilled-down action opens the per-action drawer.
test("clicking a drilled-down action opens its grading drawer", async ({ page }) => {
  await page.goto("/alex/heartbeat");

  const span = page.locator("[data-test='heartbeat-event'][data-category='Explore']");
  await span.locator("tr[data-test='heartbeat-event-row']").click();
  await span.locator("tr[data-test='heartbeat-event-action']").first().click();

  await expect(page.locator("aside[data-test='heartbeat-drawer']")).toHaveClass(/hb-drawer-open/);
});

// The event row rolls its attributed actions up into the Pokémon / Model / Tokens /
// Cost columns and a distinct open-vs-done status badge (the operator's screenshot ask).
test("the span rows show the rolled-up mascot, model, tokens, cost, and status", async ({ page }) => {
  await page.goto("/alex/heartbeat");

  const explore = page.locator("[data-test='heartbeat-event'][data-category='Explore']");
  await expect(explore.locator("[data-test='event-mascot']")).toContainText("Snorlax");
  await expect(explore.locator("[data-test='event-model']")).toContainText("opus-4-8");
  // 9.4k/360 + 6.8k/2.4k summed across the span's two seeded actions
  await expect(explore.locator("[data-test='event-tokens']")).toContainText("16.2k/2.8k");
  await expect(explore.locator("[data-test='event-cost']")).toContainText("$");
  // The Explore span's task moved to `building` during its window, so its status
  // badges as that stage (board pill + color), not the generic "done".
  await expect(explore.locator("[data-test='event-status']")).toHaveAttribute("data-stage", "building");
  await expect(explore.locator("[data-test='event-status']")).toContainText("Building");

  // The final Workflow span is still open — no in-window transition — so its status
  // badge reads "open", distinctly.
  const workflow = page.locator("[data-test='heartbeat-event'][data-category='Workflow']");
  await expect(workflow.locator("[data-test='event-status']")).toHaveText("open");
});

// The merged Status/Task cell separates the status badge from the rolled-up action
// count with a bullet, and a span whose task changed STAGE in-window badges as that
// new stage using the shared board pill.
test("the status line bullets the badge from the action count and badges a stage change", async ({ page }) => {
  await page.goto("/alex/heartbeat");

  const explore = page.locator("[data-test='heartbeat-event'][data-category='Explore']");
  // stage-change badge: the task moved to `building` during this span's window
  await expect(explore.locator("[data-test='event-status'][data-stage='building']")).toContainText("Building");
  // the bullet sits between the badge and the "N action(s)" count in the same row
  await expect(explore.locator(".hb-satline .hb-bullet")).toBeVisible();
  await expect(explore.locator("[data-test='event-action-count']")).toContainText("action");
});

// The launcher's Alex avenue links straight to the heartbeat trajectory.
test("the session launcher Alex avenue links to the heartbeat trajectory", async ({ page }) => {
  await page.goto("/launcher");

  const alex = page.locator("a[data-avenue='alex']");
  await expect(alex).toHaveAttribute("href", "/alex/heartbeat");

  await alex.click();
  await expect(page.locator("[data-test='heartbeat-event-table']")).toBeVisible();
});
