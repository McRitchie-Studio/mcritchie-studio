// [e2e] /assets — an admin drills into a folder, previews a clip, and searches.
//
// The test env browses a fixture listing (config/initializers/asset_browser.rb,
// test/fixtures/files/asset_browser_listing.yml), so no bucket is called. The
// signed URL points at fixture.invalid; the spec checks the video element and
// its src, not the bytes.
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

test("admin drills into a folder, previews a clip, and finds it by name", async ({ page }) => {
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/assets");

  await expect(page.getByRole("heading", { name: "Object store" })).toBeVisible();

  for (const folder of ["music_videos", "drake", "hotline_bling", "clips"]) {
    await page.locator("[data-test='asset-folder']", { hasText: folder }).getByRole("link").click();
    await expect(page.locator("[data-test='asset-breadcrumbs'] [aria-current='page']")).toHaveText(folder);
  }

  const clip = "music_videos/drake/hotline_bling/clips/hotline_bling_clip_01_chorus_vertical_0045_0102.mp4";
  await page.locator(`[data-test='asset-file'][data-key='${clip}']`).getByRole("link").click();

  const video = page.locator("[data-test='asset-preview'] video");
  await expect(video).toBeVisible();
  await expect(video).toHaveAttribute("src", /hotline_bling_clip_01.*X-Amz-Signature/);
  await expect(page.locator("[data-test='asset-preview-type']")).toHaveText("video/mp4");
  await expect(page.locator(`[data-test='asset-file'][data-key='${clip}']`)).toHaveAttribute("aria-current", "true");

  // Back to the root through the breadcrumbs, then search across folders.
  await page.locator("[data-test='asset-breadcrumbs']").getByRole("link", { name: "Root" }).click();
  await expect(page.locator("[data-test='asset-breadcrumbs'] [aria-current='page']")).toHaveText("Root");
  await page.getByRole("searchbox", { name: "Search file names" }).fill("portrait");
  await page.getByRole("button", { name: "Search" }).click();

  await expect(page.locator("[data-test='asset-file']")).toHaveCount(2);
  await expect(page.locator("[data-test='asset-search-bound']")).toContainText("Searched all 7 objects");
});
