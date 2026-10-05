// [e2e] The chunks panel: a tiled video shows its overlapping chunks in time
// order under the cast panel, apart from the clip candidates; the operator
// previews one and copies its filled prompt. Wholly synthetic data, seeded by
// e2e/seed.rb from db/seeds/data/tiled_video.rb.
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

test("a tiled video shows its chunks in order under the cast panel", async ({ page, context }) => {
  await context.grantPermissions(["clipboard-read", "clipboard-write"]);
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/music_videos/test-artist-a-tiled-demo");

  await expect(page.locator("[data-test='video-kind']")).toHaveText("Cinematic video · Cast");

  // Four chunks, 25 s on a 20 s stride, the last one ending at the video's end.
  const chunks = page.locator("[data-test='chunks-panel'] [data-test='chunk-row']");
  await expect(chunks).toHaveCount(4);
  await expect(chunks.locator("[data-test='chunk-window']")).toHaveText([
    /0:00–0:25\s+· 25\.0 s/, /0:20–0:45\s+· 25\.0 s/, /0:40–1:05\s+· 25\.0 s/, /1:00–1:12\s+· 12\.0 s/,
  ]);
  await expect(page.locator("[data-test='chunks-count']")).toContainText("4 chunks");

  // Below the cast, and apart from the one clip candidate, which keeps its own list.
  const castBottom = (await page.locator("[data-test='performer-card']").last().boundingBox()).y;
  const chunksTop = (await page.locator("[data-test='chunks-panel']").boundingBox()).y;
  expect(chunksTop).toBeGreaterThan(castBottom);
  await expect(page.locator("[data-test='clips-panel'] [data-test='clip-row']")).toHaveCount(1);
  await expect(page.locator("[data-test='clips-panel'] [data-test='chunk-row']")).toHaveCount(0);

  // Preview: the player loads the signed chunk only when asked.
  const chunk = page.locator("[data-test='chunk-row'][data-ordinal='2']");
  await expect(chunk.locator("[data-test='chunk-overlap']")).toHaveText("First 5 s repeat chunk 1");
  const player = chunk.locator("[data-test='chunk-player']");
  await expect(player).toBeHidden();
  await chunk.locator("[data-test='chunk-preview-button']").click();
  await expect(player).toBeVisible();
  await expect(player).toHaveAttribute("src", /tiled_demo_chunk_02_0020_0045\.mp4/);

  // Copy: the clipboard holds the filled prompt, {athlete} still a blank.
  await chunk.locator("[data-test='chunk-copy']").click();
  await expect(chunk.locator("[data-test='chunk-copy']")).toHaveText("Copied");
  const copied = await page.evaluate(() => navigator.clipboard.readText());
  expect(copied).toBe((await chunk.locator("[data-test='chunk-prompt']").textContent()).trim());
  expect(copied).toContain("Replace the man in the red jacket in this video with {athlete}");

  // A chunk has no decision; the candidate still does.
  await expect(chunk.getByRole("button", { name: "Approve" })).toHaveCount(0);
  await expect(page.locator("[data-test='clip-row']").getByRole("button", { name: "Approve" })).toHaveCount(1);
});
