const { test, expect } = require("@playwright/test");

// V1 session-resume happy path: a session-tagged task on the /tasks board shows
// a click-to-copy resume control whose display ends in the session's …<last4>
// (the glance); the full command lives in a hidden span for the clipboard.
test("tasks board shows a resume copy control ending in the session last-4", async ({ page }) => {
  await page.goto("/tasks");

  const card = page.locator("#card-session-resume-demo");
  await expect(card).toBeVisible();

  // copy control DISPLAYS the truncated, provider-aware command, ending in …<last4>
  await expect(card.locator("button", { hasText: "claude --resume …12ab" })).toBeVisible();
});
