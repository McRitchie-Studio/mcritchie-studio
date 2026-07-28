const { test, expect } = require("@playwright/test");

// [e2e] The local progression tester, driven the way the operator drives it: by
// clicking the buttons in the board header, next to New Task / Links.
//
// What this proves that the request specs cannot: the TASK group renders where it
// was moved to, its Advance button really walks a card into the WAITING APPROVAL
// state, and one more click settles that request. The waiting beat exists so the
// approval bar — the thing the operator reviews with — is reachable from a demo
// at all; the beat after it is the live demonstration that the badge drops on
// submit instead of riding the card to shipped.
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

  // And the payoff beat: submitting settles the request, so the bar drops.
  await advance.click();
  await expect(card).toHaveAttribute("data-stage", "submitted");
  await expect(waitingBar, "submitting settles the request — the badge must drop").toHaveCount(0);

  // Clean up the fixture we spawned.
  await tester.getByRole("button", { name: "Delete" }).click();
  await expect(card).toHaveCount(0);
});
