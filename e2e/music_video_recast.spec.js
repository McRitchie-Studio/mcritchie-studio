// [e2e] Swap Person on a cast card: off by default. The operator turns it on,
// searches an athlete in the wide three-column list, and picking him saves at
// once in his default look; switching the look saves again; the chunk prompts
// below follow each save without a reload. A dropped save says so and Retry
// sends it again. Turning the toggle off clears the swap. A cinematic video, so
// no prompt says "music video". Wholly synthetic data, seeded by e2e/seed.rb
// from db/seeds/data/recast_video.rb: only the operator says who is on screen
// and who replaces them.
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

const card = (page, n) => page.locator(`[data-test='performer-card'][data-ordinal='${n}']`);
const recast = (page, n) => card(page, n).locator("[data-test='performer-recast']");
// The swap search, not the look dropdown's trigger (also a combobox).
const search = (page, n) => recast(page, n).locator("[data-test='recast-typeahead'] input[role='combobox']");

test("operator turns Swap Person on, picks an athlete and a look that save at once, and sees the prompt change", async ({ page }) => {
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/music_videos/test-cinematic-recast-demo");

  await expect(page.locator("[data-test='video-kind']")).toHaveText("Cinematic video · Cast");
  await expect(page.locator("[data-test='cast-confirmed']")).toBeVisible();

  // Seeded under the old "keep as is": both read as Don't Swap Person, and no prompt names an athlete yet.
  const prompt = page.locator("#chunk-1 [data-test='chunk-prompt']");
  const toggle = recast(page, 1).locator("[data-test='swap-toggle']");
  await expect(recast(page, 1)).toHaveAttribute("data-state", "off");
  await expect(toggle).toHaveAttribute("aria-checked", "false");
  await expect(toggle).toHaveText("Don’t Swap Person");
  await expect(search(page, 1)).toBeHidden();
  await expect(prompt).toContainText("Replace the main person on screen in this video with {athlete}");

  // On reveals the search; nothing is saved until a pick.
  await toggle.click();
  await expect(toggle).toHaveAttribute("aria-checked", "true");
  await expect(toggle).toHaveText("Swap Person");
  await expect(recast(page, 1)).toHaveAttribute("data-state", "open");
  const combo = search(page, 1);
  await expect(combo).toBeFocused();

  // The list is wider than the field, three columns per row, and stays on screen.
  await combo.fill("test athlete");
  const option = recast(page, 1).locator("[data-test='recast-option']").first();
  await expect(option).toContainText("Test Athlete Alpha");
  await expect(option.locator("[data-test='search-row-badge']")).toHaveText("2 looks");
  await expect(option.locator("[data-test='search-row-look-name']")).toHaveText("Home Blue");
  const list = await recast(page, 1).locator("[data-test='recast-results']").boundingBox();
  const field = await combo.boundingBox();
  expect(list.width).toBeGreaterThan(field.width);
  expect(list.x + list.width).toBeLessThanOrEqual(page.viewportSize().width);
  const name = await option.locator("[data-test='search-row-name']").boundingBox();
  const look = await option.locator("[data-test='search-row-look-cell']").boundingBox();
  expect(look.x).toBeGreaterThan(name.x);
  expect(Math.abs(look.y - name.y)).toBeLessThan(name.height * 2);

  // The pick saves at once in his default look: no Cast button, and the chunks below follow.
  await option.click();
  await expect(recast(page, 1)).toHaveAttribute("data-state", "recast");
  await expect(recast(page, 1).locator("[data-test='swap-saved']")).toBeVisible();
  await expect(recast(page, 1).locator("[data-test='swap-athlete-name']")).toHaveText("Test Athlete Alpha");
  await expect(recast(page, 1).locator("[data-test='swap-athlete-utility']")).toContainText("athlete");
  await expect(recast(page, 1).locator("[data-test='look-cast']")).toHaveCount(0);
  await expect(prompt).toContainText("Replace the man in the red jacket in this video with Test Athlete Alpha, the football player.");
  await expect(prompt).toContainText("(like the Home Blue model provided)");
  await expect(prompt).not.toContainText("music video");
  await expect(page.locator("#chunk-1 [data-test='chunk-recast']")).toContainText("Test Athlete Alpha > Home Blue");
  await expect(page.locator("[data-test='chunk-prompt']").filter({ hasText: "Test Athlete Alpha" })).toHaveCount(4);

  // Switching the look saves it too.
  const trigger = recast(page, 1).locator("[data-test='look-trigger']");
  await trigger.click();
  await expect(recast(page, 1).locator("[data-test='look-option-name']")).toHaveText(["Home Blue", "Away White"]);
  await recast(page, 1).locator("[data-test='look-option']").filter({ hasText: "Away White" }).click();
  await expect(recast(page, 1).locator("[data-test='swap-saved']")).toBeVisible();
  await expect(prompt).toContainText("(like the Away White model provided)");
  await expect(page.locator("#chunk-1 [data-test='chunk-recast']")).toContainText("Test Athlete Alpha > Away White");

  // A dropped save says so; Retry sends it again.
  let drop = true;
  await page.route("**/performers/1/recast", (route) => (drop ? route.abort() : route.continue()));
  await trigger.click();
  await recast(page, 1).locator("[data-test='look-option']").filter({ hasText: "Home Blue" }).click();
  await expect(recast(page, 1).locator("[data-test='swap-failed']")).toBeVisible();
  await expect(recast(page, 1).locator("[data-test='swap-error']")).toHaveText("The connection dropped.");
  await expect(recast(page, 1)).toHaveAttribute("data-state", "recast");
  drop = false;
  await recast(page, 1).locator("[data-test='swap-retry']").click();
  await expect(recast(page, 1).locator("[data-test='swap-saved']")).toBeVisible();
  await expect(prompt).toContainText("(like the Home Blue model provided)");
  await page.unroute("**/performers/1/recast");

  // A reload reads the save back: on, the athlete block, the look.
  await page.reload();
  await expect(recast(page, 1)).toHaveAttribute("data-state", "recast");
  await expect(recast(page, 1).locator("[data-test='swap-athlete-name']")).toHaveText("Test Athlete Alpha");
  await expect(recast(page, 1).locator("[data-test='look-trigger']")).toHaveText("Home Blue");

  // The by-hand link lands on the athlete's look form, which knows the way back.
  await expect(recast(page, 1).locator("[data-test='recast-new-look']")).toHaveAttribute(
    "href", /\/people\/test-athlete-alpha\?return_to=%2Fmusic_videos%2Ftest-cinematic-recast-demo%23person-1#new-model$/);
  await recast(page, 1).locator("[data-test='recast-new-look']").click();
  await expect(page).toHaveURL(/\/people\/test-athlete-alpha\?return_to=/);
  await expect(page.locator("details#new-model [data-test='new-model-return']")).toBeVisible();
  await page.goBack();

  // Off clears the swap and puts the blank back.
  await recast(page, 1).locator("[data-test='swap-toggle']").click();
  await expect(recast(page, 1)).toHaveAttribute("data-state", "off");
  await expect(recast(page, 1).locator("[data-test='swap-saved']")).toBeVisible();
  await expect(prompt).toContainText("with {athlete}, the football player");
  await page.reload();
  await expect(recast(page, 1).locator("[data-test='swap-toggle']")).toHaveAttribute("aria-checked", "false");
});
