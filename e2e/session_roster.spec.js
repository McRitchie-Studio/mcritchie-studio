const { test, expect } = require("@playwright/test");

// [e2e] THE SESSION ROSTER CHASES UNWRAPPED SESSIONS. /devops/sessions lists every
// agent session with how it ended. Picking "Not wrapped" keeps the seeded session
// that never ran /wrap (and still holds an open task, so it reads Chase) and drops
// the one /wrap sealed. Read-only against the e2e-roster-* fixtures in e2e/seed.rb.
test("the Not wrapped filter keeps only sessions that never wrapped", async ({ page }) => {
  const res = await page.goto("/devops/sessions");
  expect(res.ok()).toBe(true);

  const wrapped = page.locator("[data-test='session-roster-row'][data-session='e2e-roster-wrapped']");
  const chase = page.locator("[data-test='session-roster-row'][data-session='e2e-roster-chase']");
  await expect(wrapped).toBeVisible();
  await expect(wrapped.locator("[data-test='session-roster-ending']")).toContainText("Wrapped");
  await expect(chase.locator("[data-test='session-roster-ending']")).toContainText("Chase");
  await expect(chase.locator("[data-test='session-roster-open']")).toHaveText("1");

  await page.locator("[data-test='session-roster-filter'][data-ending='not_wrapped']").click();
  await expect(page).toHaveURL(/\/devops\/sessions\?ending=not_wrapped$/);
  await expect(chase).toBeVisible();
  await expect(wrapped).toHaveCount(0);
  await expect(page.locator("[data-test='session-roster-filter'][data-ending='not_wrapped']")).toHaveAttribute("aria-current", "page");
});

// [e2e] EACH ROW CARRIES ITS RESUME COMMAND. The wrapped fixture ran in ~/projects,
// so its row offers the exact `cd … && claude --resume <id>` to copy.
test("a session row offers its resume command to copy", async ({ page }) => {
  await page.goto("/devops/sessions");
  const copy = page.locator("[data-test='session-roster-row'][data-session='e2e-roster-wrapped'] [data-test='session-roster-resume-copy']");
  await expect(copy).toBeVisible();
  await expect(copy).toHaveText("cd /Users/alex/projects && claude --resume e2e-roster-wrapped");
  await expect(copy).toHaveAttribute("data-copy-clip", "cd /Users/alex/projects && claude --resume e2e-roster-wrapped");
  // The seed has no mailbox session, so the background toggle stays hidden.
  await expect(page.locator("[data-test='session-roster-background']")).toHaveCount(0);
  // The visible command is the button's name (label in name); the title describes it.
  await expect(copy).not.toHaveAttribute("aria-label", /.*/);
  await expect(copy).toHaveAttribute("title", "Copy resume command for session e2e-rost");
});
