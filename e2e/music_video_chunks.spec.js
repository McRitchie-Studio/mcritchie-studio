// [e2e] The source video's chunks and its alt videos: the cast page lists the
// chunks in time order (cut once, shared by every alt video); Build Clips in
// the cast summary bar makes the next alt video and opens it, one clip card
// per chunk; a card previews its source chunk and copies the prompt built from
// the alt video's own swaps; the index lists it. Wholly synthetic data, seeded
// by e2e/seed.rb from db/seeds/data/tiled_video.rb.
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

test("Build Clips turns a tiled source into an alt video of clip cards", async ({ page, context }) => {
  await context.grantPermissions(["clipboard-read", "clipboard-write"]);
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/music_videos/test-artist-a-tiled-demo");

  await expect(page.locator("[data-test='video-kind']")).toHaveText("Cinematic video · Cast");

  // Four chunks, 25 s on a 20 s stride, the last one ending at the video's end.
  const windows = page.locator("[data-test='chunks-panel'] [data-test='chunk-window']");
  await expect(windows).toHaveText([/1 · 0:00–0:25/, /2 · 0:20–0:45/, /3 · 0:40–1:05/, /4 · 1:00–1:12/]);
  await expect(page.locator("[data-test='chunks-count']")).toContainText("4 chunks");
  await expect(page.locator("[data-test='clips-panel'] [data-test='clip-row']")).toHaveCount(1);

  // Build Clips sits beside Cast confirmed and opens the alt video it made.
  const bar = page.locator("[data-test='cast-progress']");
  await expect(bar.locator("[data-test='cast-confirmed']")).toBeVisible();
  const build = bar.getByRole("button", { name: "Build Clips" });
  await expect(build).toBeEnabled();
  await build.click();
  await expect(page).toHaveURL(/\/music_videos\/test-artist-a-tiled-demo\/alt_videos\/\d+#?$/);
  const number = (await page.locator("[data-test='alt-video']").getAttribute("data-number"));
  await expect(page.locator("body")).toContainText(`Alt video ${number} built: 4 clips`);
  await expect(page.locator("[data-test='alt-clip']")).toHaveCount(4);
  await expect(page.locator("[data-test='alt-progress-count']")).toHaveText("0 of 4");

  // A clip card: the source chunk loads only when asked; the prompt copies whole.
  const card = page.locator("[data-test='alt-clip'][data-ordinal='2']");
  await expect(card.locator("[data-test='clip-overlap']")).toHaveText("First 5 s repeat clip 1");
  const player = card.locator("[data-test='clip-player']");
  await expect(player).toBeHidden();
  await card.locator("[data-test='clip-preview-button']").click();
  await expect(player).toBeVisible();
  await expect(player).toHaveAttribute("src", /tiled_demo_chunk_02_0020_0045\.mp4/);
  await expect(card.locator("[data-test='clip-chunk-download']")).toHaveText("Download 25 s clip");
  await expect(card.locator("[data-test='clip-chunk-download']")).toHaveAttribute("download", "tiled_demo_chunk_02_0020_0045.mp4");
  await card.locator("[data-test='clip-copy']").click();
  await expect(card.locator("[data-test='clip-copy']")).toHaveText("Copied");
  const copied = await page.evaluate(() => navigator.clipboard.readText());
  expect(copied).toBe((await card.locator("[data-test='clip-prompt']").textContent()).trim());
  expect(copied).toContain("Replace the man in the red jacket in this video with {athlete}");

  // The index lists it, with its progress, and links back.
  await page.locator("[data-test='alt-video-index-link']").click();
  const row = page.locator(`[data-test='alt-video-row'][data-slug='test-artist-a-tiled-demo-alt-${number}']`);
  await expect(row).toContainText("Test Artist A - Tiled Demo");
  await expect(row.locator("[data-test='alt-video-row-progress']")).toContainText("0 of 4");
  await expect(row.locator("[data-test='alt-video-row-stitch']")).toHaveText("Not stitched");
  await row.click();
  await expect(page.locator("[data-test='alt-video']")).toHaveAttribute("data-number", number);
});
