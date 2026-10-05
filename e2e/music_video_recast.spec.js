// [e2e] The recast picker on a cast card: the operator searches an athlete,
// picks one of that athlete's looks from the dropdown and casts it, and the chunk prompts below name both;
// switching the look and keeping the performer as is each rewrite them. A
// cinematic video, so no prompt says "music video". Wholly synthetic data,
// seeded by e2e/seed.rb from db/seeds/data/recast_video.rb: only the operator
// says who is on screen and who replaces them.
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

const card = (page, n) => page.locator(`[data-test='performer-card'][data-ordinal='${n}']`);
const recast = (page, n) => card(page, n).locator("[data-test='performer-recast']");

test("operator picks an athlete and look and sees the prompt change", async ({ page }) => {
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/music_videos/test-cinematic-recast-demo");

  await expect(page.locator("[data-test='video-kind']")).toHaveText("Cinematic video · Cast");
  await expect(page.locator("[data-test='cast-confirmed']")).toBeVisible();

  // Seeded: both people are kept as is, so no prompt names an athlete yet.
  const prompt = page.locator("#chunk-1 [data-test='chunk-prompt']");
  await expect(recast(page, 1)).toHaveAttribute("data-state", "keep");
  await expect(prompt).toContainText("Replace the main person on screen in this video with {athlete}");

  // Change opens the picker, on a confirmed cast.
  await recast(page, 1).getByRole("button", { name: "Change" }).click();
  await expect(recast(page, 1)).toHaveAttribute("data-state", "open");

  // The typeahead finds the athlete; picking him offers his looks in a dropdown.
  await recast(page, 1).getByRole("combobox").fill("test athlete");
  const option = recast(page, 1).locator("[data-test='recast-option']").first();
  await expect(option).toContainText("Test Athlete Alpha");
  await expect(option).toContainText("2 looks");
  await option.click();
  const trigger = recast(page, 1).locator("[data-test='look-trigger']");
  const looks = recast(page, 1).locator("[data-test='look-option']");
  await trigger.click();
  await expect(looks.locator("[data-test='look-option-name']")).toHaveText(["Home Blue", "Away White"]);

  // Picking a look previews it; Cast saves, and the card and every chunk he is in now name both.
  await looks.nth(1).click();
  await expect(recast(page, 1)).toHaveAttribute("data-state", "open");
  await recast(page, 1).getByRole("button", { name: "Cast as Test Athlete Alpha > Away White" }).click();
  await expect(recast(page, 1)).toHaveAttribute("data-state", "recast");
  await expect(recast(page, 1).locator("[data-test='recast-label']")).toHaveText("Test Athlete Alpha > Away White");
  await expect(prompt).toContainText("Replace the man in the red jacket in this video with Test Athlete Alpha, the football player.");
  await expect(prompt).toContainText("(like the Away White model provided)");
  await expect(prompt).not.toContainText("music video");
  await expect(page.locator("#chunk-1 [data-test='chunk-recast']")).toContainText("Test Athlete Alpha > Away White");
  await expect(page.locator("[data-test='chunk-prompt']").filter({ hasText: "Test Athlete Alpha" })).toHaveCount(4);

  // Switching the look on the saved card rewrites the prompt.
  await trigger.click();
  await looks.filter({ hasText: "Home Blue" }).click();
  await recast(page, 1).getByRole("button", { name: "Cast as Test Athlete Alpha > Home Blue" }).click();
  await expect(recast(page, 1).locator("[data-test='recast-label']")).toHaveText("Test Athlete Alpha > Home Blue");
  await expect(prompt).toContainText("(like the Home Blue model provided)");

  // The by-hand link lands on the athlete's look form, which knows the way back.
  await expect(recast(page, 1).locator("[data-test='recast-new-look']")).toHaveAttribute(
    "href", /\/people\/test-athlete-alpha\?return_to=%2Fmusic_videos%2Ftest-cinematic-recast-demo%23person-1#new-model$/);
  await recast(page, 1).locator("[data-test='recast-new-look']").click();
  await expect(page).toHaveURL(/\/people\/test-athlete-alpha\?return_to=/);
  await expect(page.locator("details#new-model [data-test='new-model-return']")).toBeVisible();
  await page.goBack();

  // Keep as is puts the blank back.
  await recast(page, 1).getByRole("button", { name: "Change" }).click();
  await recast(page, 1).getByRole("button", { name: "Keep as is" }).click();
  await expect(recast(page, 1)).toHaveAttribute("data-state", "keep");
  await expect(prompt).toContainText("with {athlete}, the football player");
});
