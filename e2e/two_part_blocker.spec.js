const { test, expect } = require("@playwright/test");

// [e2e] The two-part blocker split. A blocker's feedback is stored as a short
// SUMMARY (Activity metadata, 4-6 words) plus the full DETAILS (Activity
// description). On the BOARD, the summary now rides a red blocker-summary bar on the
// card, linking to the detail; on the TASK PAGE, the header leads with the summary as
// the headline and the details live behind a <details> disclosure — clean glance,
// full fixing detail one click away. Read-only against the seeded
// `e2e-split-blocker-demo` fixture (an OPEN qa_feedback carrying both parts).
test("a split blocker shows the summary on the card + task header, expanding to full details", async ({ page }) => {
  // BOARD: the blocker's own summary rides a red card bar linking to the detail —
  // the deliberate upgrade to the dropped generic "UNRESOLVED QA" label.
  const boardRes = await page.goto("/tasks");
  expect(boardRes.ok()).toBe(true);
  const cardBar = page.locator("#card-e2e-split-blocker-demo [data-test='blocker-summary']");
  await expect(cardBar).toHaveText("Stage move skips server guard");
  await expect(cardBar).toHaveAttribute("href", "/tasks/e2e-split-blocker-demo");

  // TASK PAGE: the header leads with the short 4-6 word summary, not the full prose.
  const res = await page.goto("/tasks/e2e-split-blocker-demo");
  expect(res.ok()).toBe(true);
  const summary = page.locator("[data-test='task-unresolved-feedback-summary']");
  await expect(summary).toHaveText("Stage move skips server guard");

  const details = page.locator("[data-test='task-unresolved-feedback-details']");
  await expect(details).toBeVisible();

  // Collapsed by default: the full detail is tucked behind the disclosure.
  const body = details.locator("p");
  await expect(body).toBeHidden();

  // Click to expand — the builder's fixing detail is revealed in the body.
  await details.locator("summary").click();
  await expect(body).toBeVisible();
  await expect(body).toContainText("Re-gate it on the server");
});

// [e2e] The RESUBMISSION signal, on the real board and the real task page.
//
// A `--kind rework` block returns the task to `building` rather than `blocked`, so
// blocked_at / block_kind / `list --stage blocked` all read empty BY DESIGN and a
// bounced task drew exactly the same card as a never-reviewed one. This proves the
// distinction actually reaches a browser.
//
// DELIBERATELY SEEDS NOTHING. It reads two fixtures that already exist, because
// adding cards to /tasks makes the shared board heavier for every other spec on it —
// measured: two extra cards turned e2e/overflow_fade.spec.js red on CI (a fixed
// settle window that the extra Alpine work no longer fit inside) while staying green
// locally. A board-legibility feature must not pay for its own test by degrading the
// board everyone else measures. The full state matrix — unaddressed vs addressed vs
// unknown vs fresh, and the head comparison behind them — is pinned at the unit,
// component and integration tiers, where it costs the board nothing.
test("the board and task page call out a resubmission, and leave a fresh build alone", async ({ page }) => {
  const boardRes = await page.goto("/tasks");
  expect(boardRes.ok()).toBe(true);

  // A never-bounced task must still look like an ordinary build — the signal is
  // worthless if it fires on everything. e2e-ci-progress-demo carries no qa_feedback.
  await expect(
    page.locator("#card-e2e-ci-progress-demo [data-test='resubmission-state']")
  ).toHaveCount(0);

  // The split-blocker fixture DOES carry a qa_feedback row — an unclassified one,
  // which counts as a possible send-back exactly as `bin/task bounces` counts it
  // (missing a real bounce is the failure the whole circuit breaker exists to stop).
  // It records no PR branch, so there is no head to compare, and the bar must say
  // that rather than claim HEAD UNKNOWN — which would read as broken instrumentation
  // instead of the plain absence of a PR.
  const bar = page.locator("#card-e2e-split-blocker-demo [data-test='resubmission-state']");
  await expect(bar).toBeVisible();
  await expect(bar).toContainText("RESUBMISSION");
  await expect(bar).not.toContainText("HEAD UNKNOWN");
  await expect(bar).toHaveAttribute("href", "/tasks/e2e-split-blocker-demo");

  // The task page states it outright AND carries what `bin/task bounces` knows —
  // the circuit breaker's armed state — where a reader actually looks.
  const res = await page.goto("/tasks/e2e-split-blocker-demo");
  expect(res.ok()).toBe(true);

  await expect(page.locator("[data-test='task-resubmission']")).toHaveAttribute("data-state", "unknown");
  await expect(page.locator("[data-test='task-resubmission-label']")).toContainText("RESUBMISSION");
  await expect(page.locator("[data-test='task-breaker-state']")).toContainText("BREAKER ARMED");
  await expect(page.locator("[data-test='task-breaker-state']")).toContainText("1 send-back");
  await expect(page.locator("[data-test='task-resubmission-detail']")).toContainText("records no PR branch");
});
