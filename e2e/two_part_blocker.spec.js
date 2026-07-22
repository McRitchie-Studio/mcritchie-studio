const { test, expect } = require("@playwright/test");

// [e2e] The two-part blocker split on the task page. A blocker's feedback is
// stored as a short SUMMARY (Activity metadata, 4-6 words) plus the full DETAILS
// (Activity description). The task header must lead with the summary as the
// headline, and the details live behind a <details> disclosure — clean glance,
// full fixing detail one click away. Read-only against the seeded
// `e2e-split-blocker-demo` fixture (an OPEN qa_feedback carrying both parts).
test("a split blocker shows the summary headline and expands to the full details", async ({ page }) => {
  const res = await page.goto("/tasks/e2e-split-blocker-demo");
  expect(res.ok()).toBe(true);

  // The header leads with the short 4-6 word summary, not the full prose.
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
