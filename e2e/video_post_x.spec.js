const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

// [e2e] The Video Post (X) machine from the operator's chair: pick the team that
// won, attach the MP4, and land on a card that shows the drafted post the way X
// will draw it, with a Post button waiting for the click that approves it.
//
// NOT @qa-readonly: it WRITES a card. The bucket and ESPN are the e2e stand-ins
// (config/initializers/e2e_video_storage.rb): every team is 3-1 with a win
// yesterday, so the copy is fixed whatever the real season is doing.

// The stand-in kicks off at 17:00Z yesterday, so the draft carries the prime-time
// tag X::PostDraft.slot_tag gives that day: #mnf after a Monday, #tnf after a Thursday.
function expectedSlotTag() {
  const day = new Date(Date.now() - 24 * 60 * 60 * 1000).getUTCDay();
  return { 1: " #mnf", 4: " #tnf" }[day] || "";
}

async function openVideoPostForm(page) {
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/contents/new");
  await page.selectOption("select[name='content[workflow]']", "video_post_x");
}

test("operator picks the winner, uploads the MP4 and sees the post as X will draw it", async ({ page }) => {
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/contents/new");

  // The team picker and the file field belong to this workflow alone.
  const fields = page.locator("[data-test='video-post-x-fields']");
  await expect(fields).toBeHidden();
  await page.selectOption("select[name='content[workflow]']", "video_post_x");
  await expect(fields).toBeVisible();

  await page.selectOption("[data-test='video-post-x-team']", "buffalo-bills");
  await page.setInputFiles("[data-test='video-post-x-file']", {
    name: "bills-win.mp4",
    mimeType: "video/mp4",
    buffer: Buffer.from("e2e video bytes"),
  });
  await page.locator("form[action='/contents'] [type=submit]").click();

  const card = page.locator("[data-test='video-post-x-card']");
  await expect(card).toHaveAttribute("data-state", "script");
  await expect(card.locator("[data-test='video-post-x-status']")).toHaveText("Ready for your approval");

  // The drafted copy, inside the X-style preview, with its tags in X's blue.
  const preview = card.locator("[data-test='x-post-preview']");
  await expect(preview).toContainText("Turf Monster");
  await expect(preview).toContainText("@turfmonstershow");
  await expect(preview.locator("[data-test='x-post-preview-text']")).toHaveText(`Bills 3-1 #nfl #nflfootball #buffalo #bills${expectedSlotTag()}`);
  await expect(preview.locator("[data-test='x-post-preview-text'] span").first()).toHaveCSS("color", "rgb(29, 155, 240)");
  await expect(preview.locator("[data-test='video-post-x-preview']")).toHaveAttribute("src", /\/e2e-uploads\/video_posts\/content-[0-9a-f]+\.mp4\?bytes=15$/);

  // What the number was read from, and the one thing worth a look: the seeded
  // Bills carry no slogan tag.
  await expect(card.locator("[data-test='video-post-x-facts']")).toContainText("Record 3-1");
  await expect(card.locator("[data-test='video-post-x-exception']")).toContainText("no slogan hashtag");

  // The test server holds no X keys, so the button is there, off, and says why.
  await expect(card.locator("[data-test='video-post-x-post']")).toBeDisabled();
  await expect(card.locator("[data-test='video-post-x-refusal']")).toContainText("the X keys are not set on this server");
});

test("the operator can edit the copy and the preview follows", async ({ page }) => {
  await openVideoPostForm(page);
  await page.selectOption("[data-test='video-post-x-team']", "buffalo-bills");
  await page.setInputFiles("[data-test='video-post-x-file']", { name: "w.mp4", mimeType: "video/mp4", buffer: Buffer.from("x") });
  await page.locator("form[action='/contents'] [type=submit]").click();

  await page.fill("[data-test='video-post-x-copy-field']", "Bills by a mile #nfl #gobills");
  await page.locator("[data-test='video-post-x-card'] input[type=submit][value='Save copy']").click();

  await expect(page.locator("[data-test='x-post-preview-text']")).toHaveText("Bills by a mile #nfl #gobills");
  await expect(page.locator("[data-test='video-post-x-card']")).toHaveAttribute("data-state", "script");
});

test("a video post without a team or a file is refused on the form", async ({ page }) => {
  await openVideoPostForm(page);
  await page.locator("form[action='/contents'] [type=submit]").click();
  await expect(page.locator("body")).toContainText("Attach the MP4 to post.");

  await page.selectOption("select[name='content[workflow]']", "video_post_x");
  await page.setInputFiles("[data-test='video-post-x-file']", { name: "w.mp4", mimeType: "video/mp4", buffer: Buffer.from("x") });
  await page.locator("form[action='/contents'] [type=submit]").click();
  await expect(page.locator("body")).toContainText("Pick the team that won.");
});
