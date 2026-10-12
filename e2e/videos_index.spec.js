// [e2e] The source video index (/videos): a row's title opens its source
// page, whose "All videos" link comes back, and its alt video chip opens that
// alt video. At phone width the rows stack with no sideways scroll. Wholly
// synthetic data, seeded by e2e/seed.rb from db/seeds/data/lettered_video.rb.
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

const SLUG = "test-artist-b-lettered-demo";

test("index row links open the source and alt video pages", async ({ page }) => {
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/videos");

  const row = page.locator(`[data-test='video-row'][data-slug='${SLUG}']`);
  await expect(row.locator("[data-test='video-people']")).toHaveText("3 carded · 2 swapped");
  await expect(row.locator("[data-test='video-frames']")).toHaveText("3 clips missing A/B/C frames");

  await row.locator("[data-test='video-link']").click();
  await expect(page).toHaveURL(new RegExp(`/videos/${SLUG}$`));
  await expect(page.locator("[data-test='cast-panel']")).toBeVisible();

  await page.locator("[data-test='all-videos-link']").click();
  await expect(page).toHaveURL(/\/videos$/);

  const chip = row.locator("[data-test='video-alt-link']").first();
  await expect(chip).toHaveText("Alt 1 · Epsilon, Zeta");
  await chip.click();
  await expect(page).toHaveURL(new RegExp(`/videos/${SLUG}/alt_videos/1$`));
});

test("at phone width the rows stack and nothing scrolls sideways", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/videos");

  await expect(page.locator("[data-test='video-row']").first()).toBeVisible();
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
  expect(overflow).toBeLessThanOrEqual(0);
});
