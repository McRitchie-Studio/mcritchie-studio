// [e2e] The clips panel: the operator previews a clip, copies its filled swap
// prompt, and approves it, which makes the video clips ready.
// Seeded by e2e/seed.rb from db/seeds/data/night_call_clips.rb.
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

test("operator previews a clip, copies its prompt and approves it", async ({ page, context }) => {
  await context.grantPermissions(["clipboard-read", "clipboard-write"]);
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/music_videos/steve-aoki-night-call-clips");

  const rows = page.locator("[data-test='clip-row']");
  await expect(rows).toHaveCount(2);
  const clip = page.locator("[data-test='clip-row'][data-ordinal='1']");
  await expect(clip.locator("[data-test='clip-seam']")).toHaveText("Chorus → verse");
  await expect(clip.locator("[data-test='clip-shape']")).toHaveText("Solo + background");

  // Preview: the player loads the signed clip only when asked.
  const player = clip.locator("[data-test='clip-player']");
  await expect(player).toBeHidden();
  await clip.locator("[data-test='clip-preview-button']").click();
  await expect(player).toBeVisible();
  await expect(player).toHaveAttribute("src", /night_call_clips_clip_01_chorus_to_verse_solo_plus_background_0017_0042\.mp4/);

  // Copy: the clipboard holds the filled prompt, {athlete} still a blank.
  await clip.locator("[data-test='clip-copy']").click();
  await expect(clip.locator("[data-test='clip-copy']")).toHaveText("Copied");
  const copied = await page.evaluate(() => navigator.clipboard.readText());
  expect(copied).toBe((await clip.locator("[data-test='clip-prompt']").textContent()).trim());
  expect(copied).toContain("Replace the person in the desk scenes in this music video with {athlete}");

  // Approve: the clip and the video both move.
  await expect(page.locator("[data-test='video-stage']")).toHaveText("Cast confirmed");
  await clip.getByRole("button", { name: "Approve" }).click();
  await expect(clip).toHaveAttribute("data-status", "approved");
  await expect(page.locator("[data-test='video-stage']")).toHaveText("Clips ready");
  await expect(page.locator("[data-test='clips-approved-count']")).toContainText("1 of 2");
});
