const { test, expect } = require("@playwright/test");

// [e2e] The local progression tester, driven the way the operator drives it: by
// clicking the buttons in the board header, next to New Task / Links.
//
// What this proves that the request specs cannot: the TASK group renders where it
// was moved to, its Advance button really walks a card into the WAITING APPROVAL
// state, and — two beats later — the submit settles that request. The waiting beat
// exists so the approval bar (the thing the operator reviews with) is reachable
// from a demo at all; the submit beat is the live demonstration that the badge
// drops instead of riding the card to shipped.
//
// BETWEEN THEM SITS THE CI BEAT, and it is the one beat this spec does NOT drive by
// clicking: at its real cadence it settles ten checks five seconds apart, so the
// button holds its request — and this spec's attention — for ~50 seconds. It is
// posted here with beat=0 instead, which plays the identical script instantly. What
// that costs is the live TICK, which is covered where it belongs: the fan-out in
// test/services/deployments_broadcaster_test.rb, the run itself in
// test/controllers/dev/board_controller_test.rb, and the rendered meter in
// e2e/ci_meter_fit.spec.js.
//
// Fixture-scoped: every card it touches is a dev fixture (slug dev-fixture-*),
// spawned and deleted inside the test.
test("Advance walks a fixture into WAITING APPROVAL, then settles it", async ({ page }) => {
  const res = await page.goto("/tasks");
  expect(res.ok()).toBe(true);

  const tester = page.locator("[data-test='board-header-actions'] [data-test='dev-board-tools']");
  await expect(tester, "the TASK group lives in the board header").toBeVisible();
  await expect(tester.locator("span").first()).toHaveText("Task");

  const advance = tester.getByRole("button", { name: "Advance →" });

  // Spawn a fixture, then walk it: designed → building.
  //
  // Pin the card by its OWN slug, resolved once. A `[id^=card-dev-fixture-].first()`
  // locator re-resolves on every expect, so a fixture leaked by an earlier run (or a
  // parallel one) could silently become the card under assertion.
  await tester.getByRole("button", { name: "Generate" }).click();
  const spawned = page.locator('[id^="card-dev-fixture-"]').first();
  await expect(spawned).toBeVisible();
  const slug = await spawned.getAttribute("data-slug");
  const card = page.locator(`#card-${slug}`);
  await expect(card).toBeVisible();
  await advance.click();
  await expect(card).toHaveAttribute("data-stage", "building");

  // The beat under test: still building, now flashing WAITING APPROVAL.
  await advance.click();
  const waitingBar = card.locator("[data-test='operator-approval-waiting']");
  await expect(waitingBar, "the approval beat raises the bar without moving the card").toBeVisible();
  await expect(card).toHaveAttribute("data-stage", "building");

  // It is the real CTA, not a label: the whole bar is the hand-off link, which is
  // what makes the demo clickable at all.
  await expect(waitingBar).toHaveAttribute("href", `/tasks/${slug}/local_review`);

  // The CI beat (posted, not clicked — see the header): the card stays put and its
  // meter appears, which is the whole reason the beat exists.
  await page.evaluate(async () => {
    const csrf = document.querySelector('meta[name="csrf-token"]')?.content;
    await fetch("/dev/board/move?beat=0", { method: "POST", headers: { "X-CSRF-Token": csrf } });
  });
  await page.reload();
  await expect(card, "the CI beat must not move the card").toHaveAttribute("data-stage", "building");
  await expect(card.locator("[data-test='task-card-ci-progress']"),
    "a building card carries its PR's CI meter — that is the window bin/ship waits in").toBeVisible();
  await expect(card.locator("[data-test='ci-check-symbol']")).toHaveCount(10);

  // And the payoff beat: submitting settles the request, so the bar drops.
  await advance.click();
  await expect(card).toHaveAttribute("data-stage", "submitted");
  await expect(waitingBar, "submitting settles the request — the badge must drop").toHaveCount(0);

  // Clean up the fixture we spawned.
  await tester.getByRole("button", { name: "Delete" }).click();
  await expect(card).toHaveCount(0);
});
