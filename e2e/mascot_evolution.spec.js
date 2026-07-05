const { test, expect } = require("@playwright/test");

// [e2e] Mascot evolution gates: the seeded demo task walked designed→assembled,
// so its timeline shows the Pokémon line progressing — Totodile built it,
// Croconaw submitted it, Feraligatr reviewed it — and each historical card
// keeps the form that owned it. Seed-dependent, so NOT @qa-readonly.
test("task timeline shows the mascot evolving through the gates", async ({ page }) => {
  const res = await page.goto("/tasks/mascot-evolution-demo");
  expect(res.ok()).toBe(true);

  await expect(page.locator("[data-test='stage-timeline']")).toBeVisible();

  const crew = (name) => page.locator(`[data-test='timeline-crew-member'][title^='${name}']`);
  expect(await crew("Totodile").count()).toBeGreaterThanOrEqual(1); // the build lane keeps the base
  expect(await crew("Croconaw").count()).toBeGreaterThanOrEqual(1); // the submit gate's form
  await expect(page.locator("[data-test='timeline-evolution-to']")).toContainText("Feraligatr"); // the review gate's form
});
