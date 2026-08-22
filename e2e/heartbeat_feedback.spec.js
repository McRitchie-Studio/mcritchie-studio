const { test, expect } = require("@playwright/test");

// PIN THE SESSION — never rely on the page's "latest session" default.
// /alex/heartbeat defaults to HeartbeatController#latest_session_id, i.e. whichever
// session owns the newest AgentAction. These specs need the seeded heartbeat session
// (e2e/seed.rb: hb_session = 'e2e-heartbeat-0001'), whose Explore/Verify/Workflow
// spans they drill into. They used to load the bare path and got it by luck, until
// the seed grew NEWER fixtures — 'sess-test-runs' now wins that default and renders
// ZERO spans, so every locator here timed out waiting for a row that page never had.
// Measured: bare /alex/heartbeat shows 0 heartbeat-event nodes;
// ?session_id=e2e-heartbeat-0001 shows 3 (Explore, Verify, Workflow).
// e2e/alex_heartbeat.spec.js already pins it for exactly this reason — this file was
// simply never updated to match. A spec that depends on 'whatever is newest' is a
// spec the next fixture breaks.

// [e2e] The T5 feedback loop on the read-only event heartbeat: expand a span, open a
// drilled-down action's grading drawer, write Alex's grade, bank it, and confirm it
// surfaces in the Insight Bank. Grading moved entirely into the drawer — the event
// table itself is read-only (no inline radios).
test("grade a drilled-down action, bank it, and see it in the Insight Bank", async ({ page }) => {
  await page.goto("/alex/heartbeat?session_id=e2e-heartbeat-0001");
  const drawer = page.locator("aside[data-test='heartbeat-drawer']");

  // Expand a span, then open the grading drawer for its first raw action.
  const span = page.locator("[data-test='heartbeat-event'][data-category='Explore']");
  await span.locator("tr[data-test='heartbeat-event-row']").click();
  await span.locator("tr[data-test='heartbeat-event-action']").first().click();
  await expect(drawer).toHaveClass(/hb-drawer-open/);

  // The Alex grade editor is the first feedback block in the lazy-loaded drawer body.
  const alexForm = drawer.locator("form.hb-fbblock").first();
  await expect(alexForm.locator("input[name='slug']")).toBeVisible();

  const lesson = "Bank this lesson from e2e";
  await alexForm.locator("input[name='slug']").fill(lesson);
  await alexForm.locator(".hb-disptoggle button", { hasText: "Good" }).click();
  await alexForm.locator("button[value='bank']").click();

  // The drawer re-renders with the banked state (turbo_stream) — the bank button lights.
  await expect(drawer.locator("button[value='bank'].is-on").first()).toBeVisible();

  // And the lesson is curated into the Insight Bank.
  await page.goto("/alex/insights");
  await expect(page.locator("[data-test='insight-bank']")).toBeVisible();
  await expect(page.locator("[data-test='insight']", { hasText: lesson })).toBeVisible();
});

// The event table is read-only: no inline grading radios ride on the rows.
// STILL TAGGED — this asserts a design that was REVERSED, not a rotted test. It expects
// zero inline radios ("grading moved entirely into the drawer"); there are now 12, and
// app/views/heartbeat/_activity_inline_grade.html.erb exists. Inline grading came BACK.
// Its subject is gone, so it wants DELETING or rewriting to the current design — a
// coverage call, not a repair: the live behaviour IS covered Rails-side
// (test/views/heartbeat_event_table_test.rb, test/integration/heartbeat_all_spans_test.rb),
// but deleting these drops the only BROWSER coverage of grading.
test("the event heartbeat table exposes no inline grading radios @quarantine", async ({ page }) => {
  await page.goto("/alex/heartbeat?session_id=e2e-heartbeat-0001");

  await expect(page.locator("[data-test='heartbeat-event-table']")).toBeVisible();
  await expect(page.locator("[data-test='heartbeat-event-table'] input[type='radio']")).toHaveCount(0);
});

// [e2e] Grade a whole SPAN from its drawer: open the span-grade drawer, write Alex's
// grade, save (fetch -> E2 JSON), confirm the saved chip, and see the grade marker
// land on the span row live and survive a reload.
// STILL TAGGED — same design reversal. It opens the span drawer via
// [data-test='event-grade-open'], which no longer exists anywhere in app/views: span
// grading moved out of the drawer and back inline. Same delete-or-rewrite call as above.
test("grade a span from its drawer and see the marker land on the row @quarantine", async ({ page }) => {
  await page.goto("/alex/heartbeat?session_id=e2e-heartbeat-0001");
  const drawer = page.locator("aside[data-test='heartbeat-drawer']");

  const span = page.locator("[data-test='heartbeat-event'][data-category='Explore']");
  await span.locator("[data-test='event-grade-open']").click();
  await expect(drawer).toHaveClass(/hb-drawer-open/);

  const alexForm = drawer.locator("form[data-grader='alex']");
  const lesson = "tight explore span from e2e";
  await alexForm.locator("input[name='slug']").fill(lesson);
  await alexForm.locator(".hb-disptoggle button", { hasText: "Good" }).click();
  await alexForm.locator("button[value='save']").click();

  // The editor confirms the save in place (JSON round-trip, no reload).
  await expect(alexForm.locator("[data-test='span-grade-saved']")).toBeVisible();

  // The span row's Alex marker updates live via the hb:span-graded event.
  await expect(span.locator("[data-test='event-grade-alex']")).toContainText(lesson);

  // And it persists — a fresh load renders the marker server-side.
  await page.goto("/alex/heartbeat?session_id=e2e-heartbeat-0001");
  await expect(
    page.locator("[data-test='heartbeat-event'][data-category='Explore'] [data-test='event-grade-alex']")
  ).toContainText(lesson);
});

// [e2e] The per-action drawer surfaces the full tool-call command (input), not the
// clipped one-line preview the table shows.
test("the action drawer shows the full command input", async ({ page }) => {
  await page.goto("/alex/heartbeat?session_id=e2e-heartbeat-0001");

  const span = page.locator("[data-test='heartbeat-event'][data-category='Explore']");
  await span.locator("tr[data-test='heartbeat-event-row']").click();
  await span.locator("tr[data-test='heartbeat-event-action']").first().click();

  const drawer = page.locator("aside[data-test='heartbeat-drawer']");
  await expect(drawer).toHaveClass(/hb-drawer-open/);
  await expect(drawer.locator("[data-test='drawer-full-command']")).toBeVisible();
  await expect(drawer.locator("[data-test='drawer-input']")).toContainText("grep -rn AtomicEvent app/models");
});
