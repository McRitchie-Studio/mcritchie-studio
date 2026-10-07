// [e2e] Alt video asset zips (recast pipeline, piece 17): the operator downloads
// every clip's hand-off from the button at the top of the alt video, and one
// clip's from its card. Each is a real zip (starts "PK") named after the alt
// video. Wholly synthetic data, seeded by e2e/seed.rb from
// db/seeds/data/lettered_video.rb; bytes come from the test env's fixture fetcher.
const fs = require("fs");
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

async function download(page, locator) {
  const [file] = await Promise.all([page.waitForEvent("download"), locator.click()]);
  const bytes = fs.readFileSync(await file.path());
  return { name: file.suggestedFilename(), bytes };
}

test("the operator downloads the all-assets zip and a clip zip", async ({ page }) => {
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/music_videos/test-artist-b-lettered-demo/alt_videos/1");

  // At the top of the page, beside the title, without scrolling.
  const all = page.locator("header [data-test='alt-video-download-all']");
  await expect(all).toBeInViewport();
  await expect(all).toHaveText("Download all assets");
  const whole = await download(page, all);
  expect(whole.name).toBe("test-artist-b-lettered-demo_alt_1.zip");
  expect(whole.bytes.subarray(0, 2).toString()).toBe("PK");
  expect(whole.bytes.includes("test-artist-b-lettered-demo_alt_1/clip_03_0040-0105/prompt.txt")).toBe(true);
  expect(whole.bytes.includes("test-artist-b-lettered-demo_alt_1/README.txt")).toBe(true);

  const card = page.locator("[data-test='alt-clip'][data-ordinal='3']");
  const one = await download(page, card.locator("[data-test='clip-download-assets']"));
  expect(one.name).toBe("test-artist-b-lettered-demo_alt_1_clip_03.zip");
  expect(one.bytes.subarray(0, 2).toString()).toBe("PK");
  expect(one.bytes.includes("clip_03_0040-0105/frames/frame_1_ABC_0045.jpg")).toBe(true);
  expect(one.bytes.includes("clip_01_")).toBe(false);
});
