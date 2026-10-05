const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

// [e2e] The operator's half of the post-to-x flow: pick Video Post (X) on the new
// content form, attach an MP4, say what it is, and land on a card a soul can claim.
//
// NOT @qa-readonly: it WRITES a card. The bucket is the e2e stand-in
// (config/initializers/e2e_video_storage.rb), so no storage is reached.

test("operator queues an MP4 for X from the new content form", async ({ page }) => {
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/contents/new");

  // The file field belongs to this workflow alone.
  const fields = page.locator("[data-test='video-post-x-fields']");
  await expect(fields).toBeHidden();
  await page.selectOption("select[name='content[workflow]']", "video_post_x");
  await expect(fields).toBeVisible();

  await page.setInputFiles("[data-test='video-post-x-file']", {
    name: "panthers-win.mp4",
    mimeType: "video/mp4",
    buffer: Buffer.from("e2e video bytes"),
  });
  await page.fill("textarea[name='content[description]']", "Panthers win");
  await page.locator("form[action='/contents'] [type=submit]").click();

  const card = page.locator("[data-test='video-post-x-card']");
  await expect(card).toContainText("Panthers win");
  await expect(card.locator("[data-test='video-post-x-preview']")).toHaveAttribute("src", /\/e2e-uploads\/video_posts\/content-[0-9a-f]+\.mp4\?bytes=15$/);
  await expect(card.locator("[data-test='video-post-x-waiting']")).toBeVisible();
});

test("a video post without a file is refused on the form", async ({ page }) => {
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/contents/new");
  await page.selectOption("select[name='content[workflow]']", "video_post_x");
  await page.fill("textarea[name='content[description]']", "Panthers win");
  await page.locator("form[action='/contents'] [type=submit]").click();

  await expect(page.locator("body")).toContainText("Attach the MP4 to post.");
});
