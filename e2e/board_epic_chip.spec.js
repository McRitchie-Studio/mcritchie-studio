const { test, expect } = require("@playwright/test");

// [e2e] THE EPIC CHIP FILTERS THE BOARD. A card whose task carries an epic
// (tasks.epic_slug) wears a violet epic chip beside its task-slug chip; clicking
// it lands on /tasks?epic=<slug>, where the board shows only that epic's tasks
// and a banner names the epic with a way back. A card with no epic wears no
// chip at all. Read-only against the seeded `e2e-epic-chip-demo` fixture — the
// only seeded task with an epic, which is what makes "the filtered board is
// narrower" a real assertion rather than a tautology.
test("a card's epic chip filters the board to that epic", async ({ page }) => {
  const res = await page.goto("/tasks");
  expect(res.ok()).toBe(true);

  const member = page.locator("#card-e2e-epic-chip-demo");
  await expect(member).toBeVisible();
  const chip = member.locator("[data-test='task-epic-chip']");
  await expect(chip).toHaveText("devops-v3");
  await expect(chip).toHaveAttribute("href", "/tasks?epic=devops-v3");

  // A no-epic card wears no chip — the partial renders nothing rather than an
  // empty slot.
  const bystander = page.locator("#card-e2e-cleared-block-demo");
  await expect(bystander).toBeVisible();
  await expect(bystander.locator("[data-test='task-epic-chip']")).toHaveCount(0);
  const unfilteredCards = await page.locator(".kanban-card").count();
  expect(unfilteredCards).toBeGreaterThan(1);

  // The chip is an anchor inside a clickable card: its click must navigate to the
  // filter, not open the task page the card itself links to.
  await chip.click();
  await expect(page).toHaveURL(/\/tasks\?epic=devops-v3$/);

  // Filtered: the member stays, the bystander is gone, and the board is narrower.
  await expect(page.locator("#card-e2e-epic-chip-demo")).toBeVisible();
  await expect(page.locator("#card-e2e-cleared-block-demo")).toHaveCount(0);
  await expect(page.locator(".kanban-card")).toHaveCount(1);

  // The banner names the epic and offers the way back to the whole board.
  const banner = page.locator("[data-test='board-epic-filter']");
  await expect(banner).toBeVisible();
  await expect(banner).toHaveAttribute("data-epic", "devops-v3");
  await banner.locator("[data-test='board-epic-filter-clear']").click();
  await expect(page).toHaveURL(/\/tasks$/);
  await expect(page.locator("#card-e2e-cleared-block-demo")).toBeVisible();
});
