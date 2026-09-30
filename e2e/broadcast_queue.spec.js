const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

// /broadcasts/e2e-queue/queue — the staged email queue (task staged-email-queue).
//
// WHY A BROWSER TIER EARNS ITS PLACE HERE. The integration tier proves each action
// in isolation. Only a browser proves the page's form wiring: the row checkboxes and
// the "Approve selected" button live OUTSIDE the bulk form and join it with form=,
// and the execute step is a two-page walk (confirm, then send). It also measures the
// page at a phone width, where the wide table must scroll inside its card.
//
// The broadcast and its three readers come from e2e/seed.rb: two staged, one skipped.
// NOT @qa-readonly: this broadcast does not exist in production, and execute sends.

test("the queue reads as held, approves a ticked row, and executes only after the confirm", async ({ page }) => {
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/broadcasts");
  await page.locator("tr", { hasText: "Cyvasse is back" }).filter({ hasText: "queue-e2e" }).getByRole("link", { name: "Queue" }).click();

  await expect(page.getByRole("heading", { name: "Queue", level: 1 })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Locked and loaded, not sent" })).toBeVisible();
  const count = (key) => page.locator(`[data-count=${key}] [data-count-value]`);
  await expect(count("staged")).toHaveText("2");
  await expect(count("skipped")).toHaveText("1");
  await expect(page.locator("[data-skip-reasons]")).toContainText("missing first_name");

  const ann = page.locator("[data-staged-row]", { hasText: "queue-ann@example.com" });
  await expect(ann).toContainText("Ann, Cyvasse is back");

  // Preview opens the stored email in a new tab.
  const [preview] = await Promise.all([page.waitForEvent("popup"), ann.getByRole("link", { name: "Preview" }).click()]);
  await expect(preview.locator("body")).toContainText("Cyvasse is back");
  await preview.close();

  // Tick one row and approve it: the checkbox joins the bulk form from outside it.
  await ann.getByRole("checkbox").check();
  await page.getByRole("button", { name: "Approve selected" }).click();
  await expect(count("approved")).toHaveText("1");
  await expect(count("staged")).toHaveText("1");
  await expect(page.locator("[data-staged-row]", { hasText: "queue-ann@example.com" })).toHaveAttribute("data-status", "approved");

  // Execute opens a confirm step first, showing the count and the gate; nothing is sent yet.
  await page.getByRole("button", { name: "Execute approved…" }).click();
  const confirm = page.locator("[data-confirm-execute]");
  await expect(confirm.locator("[data-confirm-count]")).toHaveText("1");
  await expect(confirm).toContainText("Bounce rate");
  await expect(count("sent")).toHaveText("0");

  await confirm.getByRole("button", { name: "Yes, send 1" }).click();
  await expect(page.locator("[data-staged-row]", { hasText: "queue-ann@example.com" })).toHaveAttribute("data-status", /queued|sent/);
  await expect(page.locator("[data-staged-row]", { hasText: "queue-bob@example.com" })).toHaveAttribute("data-status", "staged");
});

test("at 375px the queue page itself never scrolls sideways", async ({ page }) => {
  await page.setViewportSize({ width: 375, height: 812 });
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/broadcasts/e2e-queue/queue");
  await expect(page.locator("[data-locked-banner]")).toBeVisible();
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
  expect(overflow).toBeLessThanOrEqual(0);
});
