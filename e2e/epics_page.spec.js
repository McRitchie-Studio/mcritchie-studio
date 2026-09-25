const { test, expect } = require("@playwright/test");
const { watchPageErrors } = require("./helpers");

// [e2e] THE EPIC VIEW CLICKS THROUGH. /epics lists each epic with a row that links
// to /epics/<slug>, and that page draws the epic's tasks on the BOARD'S OWN CARD,
// grouped by stage. The card reads four helpers from its board's Alpine scope
// (matchesFilter, appVisible, archiveTask, deleteTask); the epic page supplies its
// own, and a missing one would throw on render and hide every card — so the spec
// asserts the cards are VISIBLE and the page raised no errors, which no request
// test can see.
//
// THE SPEC OWNS ITS OWN FIXTURES and deletes them, rather than seeding
// e2e/seed.rb: other specs measure the shared board, so a permanently seeded card
// changes their input (see e2e/board_local_check.spec.js).

const EPIC = "e2e-epic-view";

// The board carries a signed API token for exactly this purpose (meta e2e-api-token).
const api = (page, method, path, body) =>
  page.evaluate(
    async ([m, p, b]) => {
      const token = document.querySelector('meta[name="e2e-api-token"]')?.content;
      const res = await fetch(p, {
        method: m,
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
        body: b ? JSON.stringify(b) : undefined,
      });
      return { status: res.status, body: await res.text() };
    },
    [method, path, body]
  );

const fixtures = [
  { slug: "e2e-epic-view-building", title: "E2E epic view building", stage: "building" },
  { slug: "e2e-epic-view-designed", title: "E2E epic view designed", stage: "designed" },
];

test("the epics page lists an epic and clicks through to its tasks by stage", async ({ page }) => {
  await page.goto("/tasks");
  for (const task of fixtures) {
    const created = await api(page, "POST", "/api/v1/tasks", {
      ...task,
      epic_slug: EPIC,
      devops: { repositories: ["mcritchie-studio"] },
    });
    expect([200, 201], `create ${task.slug}: ${created.body.slice(0, 200)}`).toContain(created.status);
  }

  try {
    const { pageErrors, report } = watchPageErrors(page);

    // The board's own link row reaches the index.
    await page.locator("[data-test='board-link-epics']").first().click();
    await expect(page).toHaveURL(/\/epics$/);

    const row = page.locator(`[data-test='epic-row'][data-epic='${EPIC}']`);
    await expect(row).toBeVisible();
    await expect(row.locator("[data-test='epic-progress']")).toHaveAttribute("data-total", "2");
    await expect(row.locator("[data-test='epic-stage-count'][data-stage='building']")).toContainText("1");

    await row.locator("[data-test='epic-row-link']").click();
    await expect(page).toHaveURL(new RegExp(`/epics/${EPIC}$`));
    await expect(page.locator("[data-test='epic-header'] h1")).toHaveText(EPIC);

    // Each task sits in its stage's section, on a card that actually shows.
    const building = page.locator("[data-test='epic-stage'][data-stage='building']");
    const designed = page.locator("[data-test='epic-stage'][data-stage='designed']");
    await expect(building.locator("#card-e2e-epic-view-building")).toBeVisible();
    await expect(designed.locator("#card-e2e-epic-view-designed")).toBeVisible();
    await expect(page.locator("#card-e2e-epic-view-building [data-test='task-epic-chip']")).toHaveText(EPIC);

    expect(pageErrors, report()).toHaveLength(0);
  } finally {
    await page.goto("/tasks");
    for (const task of fixtures) await api(page, "DELETE", `/api/v1/tasks/${task.slug}`);
  }
});
