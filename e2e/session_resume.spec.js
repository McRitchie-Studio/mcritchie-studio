const { test, expect } = require("@playwright/test");

// V1 session-resume happy path. The click-to-copy resume control moved OFF the
// /tasks board cards onto the task READ view (app/views/tasks/show.html.erb),
// gated on the task having a session id. It DISPLAYS the truncated, provider-aware
// command ending in the session's …<last4>; the FULL command lives in a hidden
// span for the clipboard. Driven against the seeded `session-resume-demo` fixture
// (session_id …12ab, provider claude).
test("task show page shows a resume copy control ending in the session last-4", async ({ page }) => {
  await page.goto("/tasks/session-resume-demo");

  // The copy control DISPLAYS the truncated, provider-aware command, ending in …<last4>.
  await expect(page.locator("button", { hasText: "claude --resume …12ab" })).toBeVisible();

  // The FULL resume command lives in a hidden span (x-ref) for the clipboard write.
  await expect(page.locator("[x-ref='resumeCmd']")).toContainText("claude --resume");
});
