const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

// [e2e] The board UI edit is a PARTIAL devops write.
//
// The edit form renders a field for some devops keys and not others. That post
// used to be written over metadata.devops WHOLESALE, so every key the form omits
// — agent_context (often the only record of WHY a task exists), built_by,
// gem_bump, pr_urls, the mascot/session keys — was deleted by anyone editing a
// field in a browser. Silently, with a 200.
//
// This is the acceptance criterion in its own medium: a real browser, the real
// form, a real submit. The request-level tests read the form's field set off the
// rendered page and post it; only this one proves the browser SENDS that set.
//
// BOTH assertions after the save are load-bearing. Asserting only that
// agent_context survived would pass on a save that never happened — a 422 leaves
// the old value on the page too. So the spec first proves the edit LANDED (the
// branch it changed is on the show page), and only then that it took nothing
// with it.
test("a board edit preserves the devops keys its form never renders", async ({ page }) => {
  await loginWithMagicLink(page, "alex@test.com");

  const taskPath = "/tasks/e2e-devops-key-preservation-demo";
  await page.goto(taskPath);
  await expect(page.getByText("AGENT-CONTEXT-SURVIVES-THE-EDIT")).toBeVisible();

  await page.goto(`${taskPath}/edit`);
  const branch = page.locator('input[name="task[devops][branch]"]');
  await expect(branch).toHaveValue("feat/before-the-edit");
  // The premise: the form offers no way to resend agent_context, so anything that
  // survives below survives because it was never posted.
  await expect(page.locator('[name="task[devops][agent_context]"]')).toHaveCount(0);

  await branch.fill("feat/after-the-edit");
  await page.click('button[type="submit"]');
  await page.waitForURL(`**${taskPath}`);

  await expect(page.getByText("feat/after-the-edit")).toBeVisible();
  await expect(page.getByText("AGENT-CONTEXT-SURVIVES-THE-EDIT")).toBeVisible();
});
