const { test, expect } = require("@playwright/test");

// /admin/agent_messages — the agent mailbox, watched.
//
// The component tier (test/controllers/admin/agent_messages_controller_test.rb)
// proves each filter's query and the timeline markup. This walks them the way
// the operator does: click a soul, then a status on top of it, and check the
// first survived; then open a message and follow its timeline to the reply link.
//
// NOT @qa-readonly: it reads rows e2e/seed.rb owns, which production never has.

const rows = (page) => page.locator("#am-rows tbody tr");

test("filter the inbox by soul and status, then open a message's timeline", async ({ page }) => {
  await page.goto("/admin/agent_messages");
  await expect(page.getByRole("heading", { name: "Agent inbox" })).toBeVisible();
  expect(await rows(page).count()).toBeGreaterThanOrEqual(4);

  // SOUL — click it like an operator.
  await page.locator("#am-filters").getByRole("link", { name: "avi", exact: true }).click();
  await expect(page).toHaveURL(/soul=avi/);
  const souls = await rows(page).evaluateAll((els) => els.map((el) => el.dataset.soul));
  expect(souls.length).toBe(2);
  expect(souls.every((s) => s === "avi")).toBe(true);

  // STATUS on top of soul: the soul filter must survive the click.
  await page.locator("#am-filters").getByRole("link", { name: /^claimed \(/ }).click();
  await expect(page).toHaveURL(/soul=avi/);
  await expect(page).toHaveURL(/status=claimed/);
  await expect(rows(page)).toHaveCount(1);
  await expect(rows(page).first()).toContainText("e2e-laptop-202-def456");
  await expect(rows(page).first()).toContainText(/lease \d+m \d+s left/);

  // A filter with nothing behind it says so.
  await page.locator("#am-filters").getByRole("link", { name: /^dead \(/ }).click();
  await expect(page.locator("#am-empty")).toContainText("matching these filters");

  // The answered message: its timeline, ending in the Discord reply.
  await page.goto("/admin/agent_messages?status=completed");
  // Filtered by its text, not taken first: other specs' seeds (e2e/app_usage_meter.spec.js)
  // add completed rows of their own, newer than this one.
  await rows(page).filter({ hasText: /e2e release green/ }).first().getByRole("link", { name: /e2e release green/ }).click();
  await expect(page.getByRole("heading", { name: /Message \d+/ })).toBeVisible();
  await expect(page.locator("#am-status")).toHaveText("completed");
  const kinds = await page.locator("#am-timeline li").evaluateAll((els) => els.map((el) => el.dataset.kind));
  expect(kinds).toEqual(["received", "routed", "claimed", "completed", "reply_posted"]);
  await expect(page.locator("#am-reply-link a")).toHaveAttribute(
    "href",
    "https://discord.com/channels/910000000000000001/910000000000000002/910000000000000099",
  );
  await expect(page.locator("body")).toContainText("rel-e2e is green and waiting on QA.");
});
