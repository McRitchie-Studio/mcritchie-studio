const { test, expect } = require("@playwright/test");

// The Alex avenue (/alex/heartbeat) renders the agent-narrated EVENT trajectory from
// the seeded spans — each row an AtomicEvent (category · reason -> outcome) that
// drills down (Alpine) into the raw tool-calls attributed to it. The seed narrates a
// couple of closed spans, a final OPEN span ("…in progress"), plus one pre-narration
// action in the read-only "Unlabeled" group.
test("alex heartbeat renders the narrated event spans as the primary rows", async ({ page }) => {
  await page.goto("/alex/heartbeat?session_id=e2e-heartbeat-0001");

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
  await page.goto("/alex/heartbeat?session_id=e2e-heartbeat-0001");

  const span = page.locator("[data-test='heartbeat-event'][data-category='Explore']");
  const firstAction = span.locator("tr[data-test='heartbeat-event-action']").first();

  // Collapsed by default — the action drill-down rows are hidden.
  await expect(firstAction).toBeHidden();

  // Expand the span; its raw tool-calls become visible, showing kind + input.
  await span.locator("tr[data-test='heartbeat-event-row']").click();
  await expect(firstAction).toBeVisible();
  await expect(firstAction).toContainText("grep");
});

// The seeded Explore span carries a span-level key method (ruby) and its explore
// action a bash one + a goal summary — each renders as a copyable chip with a
// leading language badge and a copy button (the operator's key-method ask).
test("key methods render as copyable chips with language badges", async ({ page }) => {
  await page.goto("/alex/heartbeat?session_id=e2e-heartbeat-0001");

  // The span-level chip sits under the narration lines.
  const spanChip = page.locator("[data-test='event-key-method'] [data-test='key-method-chip']").first();
  await expect(spanChip).toBeVisible();
  await expect(spanChip.locator("[data-test='key-method-lang']")).toHaveText("ruby");
  await expect(spanChip.locator("[data-test='key-method-copy']")).toBeVisible();

  // Expanding the Explore span (the seq-cell chevron is the expand affordance —
  // a row-body click opens the grading drawer instead) reveals its action's bash
  // chip + goal summary.
  const span = page.locator("[data-test='heartbeat-event'][data-category='Explore']");
  await span.locator("tr[data-test='heartbeat-event-row'] td.hb-seq").click();
  const actionChip = span.locator("[data-test='action-key-method'] [data-test='key-method-chip']").first();
  await expect(actionChip).toBeVisible();
  await expect(actionChip.locator("[data-test='key-method-lang']")).toHaveText("bash");
  await expect(span.locator("[data-test='action-summary']").first()).toHaveText("find the capture model seam");
});

// Grading is preserved: clicking a drilled-down action opens the per-action drawer.
test("clicking a drilled-down action opens its grading drawer", async ({ page }) => {
  await page.goto("/alex/heartbeat?session_id=e2e-heartbeat-0001");

  const span = page.locator("[data-test='heartbeat-event'][data-category='Explore']");
  await span.locator("tr[data-test='heartbeat-event-row']").click();
  await span.locator("tr[data-test='heartbeat-event-action']").first().click();

  await expect(page.locator("aside[data-test='heartbeat-drawer']")).toHaveClass(/hb-drawer-open/);
});

// The event row rolls its attributed actions up into the Pokémon / Model / Tokens /
// Cost columns and a distinct open-vs-done status badge (the operator's screenshot ask).
test("the span rows show the rolled-up mascot, model, tokens, cost, and status", async ({ page }) => {
  await page.goto("/alex/heartbeat?session_id=e2e-heartbeat-0001");

  const explore = page.locator("[data-test='heartbeat-event'][data-category='Explore']");
  // the mascot name rides on the avatar's title (the face itself is a sprite/initial)
  await expect(explore.locator("[data-test='event-mascot']")).toHaveAttribute("title", "Snorlax");
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

// The activity card carries the status badge (TOP, floated right) and the rolled-up
// action count (MIDDLE, floated right); a span whose task changed STAGE in-window
// badges as that new stage using the shared board pill.
test("the activity card carries the status badge and action count and badges a stage change", async ({ page }) => {
  await page.goto("/alex/heartbeat?session_id=e2e-heartbeat-0001");

  const explore = page.locator("[data-test='heartbeat-event'][data-category='Explore']");
  const card = explore.locator("[data-test='activity-card']");
  // stage-change badge: the task moved to `building` during this span's window
  await expect(card.locator("[data-test='event-status'][data-stage='building']")).toContainText("Building");
  // the rolled-up action count sits on the card's middle line
  await expect(card.locator("[data-test='event-inline-action-count']")).toContainText("action");
});

// The card renders finish/start times to the SECOND: a closed span shows its
// completed_at (top) and created_at (middle); the open span counts UP with a live
// elapsed timer and a spinner instead.
test("activity + action timestamps render at second precision", async ({ page }) => {
  await page.goto("/alex/heartbeat?session_id=e2e-heartbeat-0001");

  // A closed span's card shows completed_at (top) and created_at (middle), each with
  // a HH:MM:SS clock — a colon-delimited time, not the minute-only heartbeat stamp.
  const verify = page.locator("[data-test='heartbeat-event'][data-category='Verify']");
  const verifyCard = verify.locator("[data-test='activity-card']");
  await expect(verifyCard.locator("[data-test='activity-completed']")).toContainText(/\d{2}:\d{2}:\d{2}/);
  await expect(verifyCard.locator("[data-test='activity-created']")).toContainText("created");

  // The still-open Workflow span counts up with a live timer + spinner, no completed.
  const workflowCard = page
    .locator("[data-test='heartbeat-event'][data-category='Workflow']")
    .locator("[data-test='activity-card']");
  await expect(workflowCard.locator("[data-test='activity-elapsed']")).toBeVisible();
  await expect(workflowCard.locator("[data-test='activity-spinner']")).toBeVisible();
  await expect(workflowCard.locator("[data-test='activity-completed']")).toHaveCount(0);

  // Expanding the Explore span reveals its action rows, whose top line is the
  // created -> completed span.
  const explore = page.locator("[data-test='heartbeat-event'][data-category='Explore']");
  await explore.locator("tr[data-test='heartbeat-event-row'] td.hb-seq").click();
  await expect(explore.locator("[data-test='action-span']").first()).toContainText("created at");
});

// The launcher's Alex avenue links straight to the heartbeat trajectory.
test("the session launcher Alex avenue links to the heartbeat trajectory", async ({ page }) => {
  await page.goto("/launcher");

  const alex = page.locator("a[data-avenue='alex']");
  await expect(alex).toHaveAttribute("href", "/alex/heartbeat");

  await alex.click();
  await expect(page.locator("[data-test='heartbeat-event-table']")).toBeVisible();
});
