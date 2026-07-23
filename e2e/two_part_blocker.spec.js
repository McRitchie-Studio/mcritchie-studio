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
