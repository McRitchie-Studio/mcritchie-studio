const { test, expect } = require("@playwright/test");

// [e2e] Mascot evolution gates: the seeded demo task walked designed→assembled,
// so its timeline shows the Pokémon line progressing — and shows WHERE each gate
// fires. Both gates sit on the accepting side of the submit seam: Totodile built
// it AND submitted it (handing work over spends nothing), Croconaw is what the
// REVIEW gate made of it, and Feraligatr is what ASSEMBLE did.
// Seed-dependent, so NOT @qa-readonly.
test("task timeline shows the mascot evolving at the review and assemble gates", async ({ page }) => {
  const res = await page.goto("/tasks/mascot-evolution-demo");
  expect(res.ok()).toBe(true);

  await expect(page.locator("[data-test='stage-timeline']")).toBeVisible();

  const crew = (name) => page.locator(`[data-test='timeline-crew-member'][title^='${name}']`);
  expect(await crew("Totodile").count()).toBeGreaterThanOrEqual(1); // the build lane keeps the base

  // THE GATE THAT MOVED. Submitting is a hand-off, not an acceptance, so the
  // submitted block still wears the form that BUILT the task. Before 2026-08-15
  // this block showed Croconaw.
  const submitted = page.locator("[data-test='timeline-block'][data-stage='submitted']");
  await expect(submitted).toHaveCount(1);
  expect(await submitted.locator("[data-test='timeline-crew-member'][title^='Totodile']").count())
    .toBeGreaterThanOrEqual(1);

  // The reveal is the FINAL form, and it now belongs to the assemble gate: one
  // Evolve reel, Croconaw (what the review gate made) → Feraligatr.
  const evolve = page.locator("[data-test='timeline-block'][data-stage='evolve']");
  await expect(evolve).toHaveCount(1);
  await expect(evolve.locator("[data-test='timeline-evolution-from']")).toContainText("Croconaw");
  await expect(evolve.locator("[data-test='timeline-evolution-to']")).toContainText("Feraligatr");

  // It is spliced after Reviewed → Assembled, not after the review.
  const order = await page.locator("[data-test='timeline-block']").evaluateAll((els) =>
    els.map((el) => el.dataset.stage)
  );
  expect(order.slice(-2)).toEqual(["assembled", "evolve"]);
});
