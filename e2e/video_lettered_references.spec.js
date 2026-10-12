// [e2e] Lettered clip references (recast pipeline, piece 16): a clip that swaps
// two people names both by their source letter and jersey number, the lead and
// the background, shows its lettered frames above the hand-off, and labels each
// person's sheet as the prompt numbers it. The cast card carries the same
// letter. Wholly synthetic data, seeded by e2e/seed.rb from
// db/seeds/data/lettered_video.rb.
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

test("a clip with two swaps shows both letters, numbers and sheets", async ({ page }) => {
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/videos/test-artist-b-lettered-demo/alt_videos/1");

  const card = page.locator("[data-test='alt-clip'][data-ordinal='3']");
  const rows = card.locator("[data-test='clip-swap-row']");
  await expect(rows).toHaveCount(2);
  await expect(card.locator("[data-test='clip-swap-row'][data-letter='B'][data-lead='true']")).toContainText("#4 Test Passer Epsilon");
  await expect(card.locator("[data-test='clip-swap-row'][data-letter='C'][data-lead='false']")).toContainText("#88 Test Receiver Zeta");

  // The lettered frames, above the hand-off.
  const frames = card.locator("[data-test='clip-frame']");
  await expect(frames).toHaveCount(2);
  await expect(frames.first()).toContainText("A B C");
  const framesBox = await card.locator("[data-test='clip-frames']").boundingBox();
  const handoffBox = await card.locator("[data-test='clip-handoff']").boundingBox();
  expect(framesBox.y).toBeLessThan(handoffBox.y);

  // Each swapped person's sheet, numbered as the prompt numbers it.
  const handoff = card.locator("[data-test='clip-handoff']");
  await expect(handoff).toContainText("Sheet 1 · Person B · #4 Test Passer Epsilon");
  await expect(handoff).toContainText("Sheet 2 · Person C · #88 Test Receiver Zeta");

  const prompt = card.locator("[data-test='clip-prompt']");
  await expect(prompt).toContainText("People are marked A, B, C... in the reference frames.");
  await expect(prompt).toContainText("- Person B (lead) -> #4 Test Passer Epsilon, Home White (character sheet 1)");
  await expect(prompt).toContainText("- Person C (background) -> #88 Test Receiver Zeta, Home White (character sheet 2)");
  await expect(prompt).toContainText("#4 Test Passer Epsilon should also be mouthing all the mouth movements of Person B.");

  // The cast card calls Person 2 B too.
  await page.goto("/videos/test-artist-b-lettered-demo");
  await expect(page.locator("[data-test='performer-card'][data-ordinal='2'] [data-test='performer-letter']")).toHaveText("B");
});

// [e2e] Chunks with people on screen and no lettered frames: one warning near
// the top of the page and a "No A/B/C frames" note on each such card. In the
// seed only chunk 3 has frames, and Person A is sighted throughout.
test("the page warns about chunks with people on screen and no lettered frames", async ({ page }) => {
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/videos/test-artist-b-lettered-demo/alt_videos/1");

  const warning = page.locator("[data-test='alt-video-frames-missing']");
  await expect(warning).toHaveText(
    "3 of 4 clips have no A/B/C frames yet. Higgsfield works best with them: ask the agent to run lettered references."
  );
  const warningBox = await warning.boundingBox();
  const swapsBox = await page.locator("[data-test='alt-video-swaps']").boundingBox();
  expect(warningBox.y).toBeLessThan(swapsBox.y);

  for (const ordinal of [1, 2, 4]) {
    await expect(page.locator(`[data-test='alt-clip'][data-ordinal='${ordinal}'] [data-test='clip-frames-missing']`)).toHaveText("No A/B/C frames");
  }
  await expect(page.locator("[data-test='alt-clip'][data-ordinal='3'] [data-test='clip-frames-missing']")).toHaveCount(0);
});
