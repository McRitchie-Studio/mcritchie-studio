const { test, expect } = require("@playwright/test");

// [e2e] The T5 feedback loop on the read-only event heartbeat: expand a span, open a
// drilled-down action's grading drawer, write Alex's grade, bank it, and confirm it
// surfaces in the Insight Bank. Grading moved entirely into the drawer — the event
// table itself is read-only (no inline radios).
test("grade a drilled-down action, bank it, and see it in the Insight Bank @quarantine", async ({ page }) => {
  await page.goto("/alex/heartbeat");
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
test("the event heartbeat table exposes no inline grading radios @quarantine", async ({ page }) => {
  await page.goto("/alex/heartbeat");

  await expect(page.locator("[data-test='heartbeat-event-table']")).toBeVisible();
  await expect(page.locator("[data-test='heartbeat-event-table'] input[type='radio']")).toHaveCount(0);
});

// [e2e] Grade a whole SPAN from its drawer: open the span-grade drawer, write Alex's
// grade, save (fetch -> E2 JSON), confirm the saved chip, and see the grade marker
// land on the span row live and survive a reload.
test("grade a span from its drawer and see the marker land on the row @quarantine", async ({ page }) => {
  await page.goto("/alex/heartbeat");
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
  await page.goto("/alex/heartbeat");
  await expect(
    page.locator("[data-test='heartbeat-event'][data-category='Explore'] [data-test='event-grade-alex']")
  ).toContainText(lesson);
});

// [e2e] The per-action drawer surfaces the full tool-call command (input), not the
// clipped one-line preview the table shows.
test("the action drawer shows the full command input @quarantine", async ({ page }) => {
  await page.goto("/alex/heartbeat");

  const span = page.locator("[data-test='heartbeat-event'][data-category='Explore']");
  await span.locator("tr[data-test='heartbeat-event-row']").click();
  await span.locator("tr[data-test='heartbeat-event-action']").first().click();

  const drawer = page.locator("aside[data-test='heartbeat-drawer']");
  await expect(drawer).toHaveClass(/hb-drawer-open/);
  await expect(drawer.locator("[data-test='drawer-full-command']")).toBeVisible();
  await expect(drawer.locator("[data-test='drawer-input']")).toContainText("grep -rn AtomicEvent app/models");
});
