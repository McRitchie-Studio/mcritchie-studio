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

// [e2e] The resubmission distinction. A `--kind rework` block leaves the task on
// `building`, so a bounced task and a never-reviewed one drew the same card and the
// board could not say "this is a resubmission carrying unaddressed feedback". These
// two fixtures differ ONLY in whether the PR head moved after the send-back — the
// honest signal, since unresolved_feedback holds prose and is cleared by ceremony
// rather than by the work landing. Read-only against the seeded pair.
test("the board distinguishes a resubmission with an unmoved head from one that addressed it", async ({ page }) => {
  const res = await page.goto("/tasks");
  expect(res.ok()).toBe(true);

  const unmoved = page.locator("#card-e2e-resubmission-unmoved [data-test='resubmission-state']");
  const addressed = page.locator("#card-e2e-resubmission-addressed [data-test='resubmission-state']");

  await expect(unmoved).toBeVisible();
  await expect(addressed).toBeVisible();

  // The unmoved head is the one a reviewer must not re-read: called out, in red.
  await expect(unmoved).toContainText("FEEDBACK NOT ADDRESSED");
  await expect(unmoved).toHaveClass(/bg-red-500/);

  // The addressed one is a heads-up, not an alarm — and it must NOT read the same.
  await expect(addressed).toContainText("ADDRESSED");
  await expect(addressed).not.toContainText("NOT ADDRESSED");
  await expect(addressed).toHaveClass(/bg-amber-500/);

  const unmovedText = (await unmoved.textContent()).trim();
  const addressedText = (await addressed.textContent()).trim();
  expect(unmovedText).not.toBe(addressedText);
});

test("a fresh build carries no resubmission bar, and the task page states the breaker", async ({ page }) => {
  // A never-bounced task must still look like an ordinary build — the signal is
  // worthless if it fires on everything. e2e-ci-progress-demo carries no qa_feedback.
  await page.goto("/tasks");
  await expect(
    page.locator("#card-e2e-ci-progress-demo [data-test='resubmission-state']")
  ).toHaveCount(0);

  // The split-blocker fixture, by contrast, DOES carry a qa_feedback row — an
  // unclassified one, which counts as a possible send-back exactly as bin/task
  // bounces counts it. It records no PR branch, so there is no head to compare, and
  // the bar must say that rather than claim HEAD UNKNOWN (which would read as broken
  // instrumentation instead of the plain absence of a PR).
  const noPr = page.locator("#card-e2e-split-blocker-demo [data-test='resubmission-state']");
  await expect(noPr).toContainText("RESUBMISSION");
  await expect(noPr).not.toContainText("HEAD UNKNOWN");

  // The task page carries what `bin/task bounces` knows — TRIPPED plus the prior
  // send-back count — where a reader actually looks.
  const res = await page.goto("/tasks/e2e-resubmission-unmoved");
  expect(res.ok()).toBe(true);

  await expect(page.locator("[data-test='task-resubmission']")).toHaveAttribute("data-state", "unaddressed");
  await expect(page.locator("[data-test='task-resubmission-label']")).toContainText("FEEDBACK NOT ADDRESSED");
  await expect(page.locator("[data-test='task-breaker-state']")).toContainText("BREAKER ARMED");
  await expect(page.locator("[data-test='task-breaker-state']")).toContainText("1 send-back");
  await expect(page.locator("[data-test='task-resubmission-heads']")).toContainText("029a945b");
});
