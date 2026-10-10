// [e2e] The standing TikTok connection page, /admin/tiktok, walked the way an
// admin meets it: not connected, Sign in, the connected page, back to the
// standing page (now connected, with the account and no token), Disconnect with
// its confirm, and not connected again. At phone width nothing on it runs off
// the side.
//
// WHAT THIS DOES NOT PROVE. TikTok is the lane's stand-in
// (config/initializers/tiktok_draft_stand_in.rb): the authorize step comes
// straight back to the callback and the code exchange answers a synthetic
// grant. The callback, the stored connection, the page and the disconnect are
// real. The spec ends as it began, with no connection stored.
//
// TIKTOK_PAGE_SHOTS=<dir> also saves the page in both states, desktop and
// 390px, for a reviewer to look at.
const path = require("path");
const { test, expect } = require("@playwright/test");

const SHOTS = process.env.TIKTOK_PAGE_SHOTS;
const DESKTOP = { width: 1280, height: 900 };
const PHONE = { width: 390, height: 844 };

// The page at both widths: nothing wider than the window, and a picture when asked.
const atBothWidths = async (page, name) => {
  for (const [label, size] of [["desktop", DESKTOP], ["390", PHONE]]) {
    await page.setViewportSize(size);
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
    expect(overflow, `${name} at ${label}: nothing runs off the side`).toBeLessThanOrEqual(0);
    const section = await page.locator("[data-test='tiktok-connection']").boundingBox();
    expect(section.x).toBeGreaterThanOrEqual(0);
    expect(section.x + section.width).toBeLessThanOrEqual(size.width);
    if (SHOTS) await page.screenshot({ path: path.join(SHOTS, `admin-tiktok-${name}-${label}.png`), fullPage: true });
  }
  await page.setViewportSize(DESKTOP);
};

test("an admin sees the TikTok connection, signs in, and disconnects, all from the standing page", async ({ page }) => {
  const root = page.locator("[data-test='tiktok-connection']");
  const disconnect = page.locator("form[data-test='tiktok-disconnect'] button");

  // Start from nothing stored, whatever an earlier run left.
  await page.goto("/admin/tiktok");
  page.on("dialog", (dialog) => dialog.accept());
  if (await disconnect.count()) {
    await disconnect.click();
    await expect(root).toHaveAttribute("data-source", "none");
  }

  await expect(root).toHaveAttribute("data-source", "none");
  await expect(page.locator("[data-test='tiktok-status-badge']")).toHaveText("Not connected");
  await expect(disconnect).toHaveCount(0);
  await expect(page.locator("[data-tiktok-field='stand-in']")).toBeVisible();
  await atBothWidths(page, "not-connected");

  // Sign in: the stand-in answers for TikTok, and the callback stores the connection.
  await page.locator("[data-test='tiktok-sign-in']").click();
  await expect(page.locator("[data-tiktok-connected] h1")).toHaveText("TikTok connected and saved");
  await page.locator("[data-test='tiktok-connection-link']").click();

  await expect(page).toHaveURL(/\/admin\/tiktok$/);
  await expect(root).toHaveAttribute("data-source", "stored");
  await expect(page.locator("[data-test='tiktok-status-badge']")).toHaveText("Connected");
  await expect(page.locator("[data-tiktok-field='account']")).toHaveText("stand-in-account");
  await expect(page.locator("[data-tiktok-field='scope']")).toHaveText("user.info.basic,video.upload");
  await expect(page.locator("[data-tiktok-field='readable']")).toHaveAttribute("data-readable", "true");
  await expect(page.locator("[data-test='tiktok-sign-in']")).toHaveText("Sign in again");
  // The stand-in's tokens start "stand-in-refresh-" and "stand-in-access-": neither is on the page.
  expect(await page.content()).not.toMatch(/stand-in-(refresh|access)/);
  await atBothWidths(page, "connected");

  // Disconnect asks first (the dialog is accepted above), then lands back here.
  await disconnect.click();
  await expect(page).toHaveURL(/\/admin\/tiktok$/);
  await expect(root).toHaveAttribute("data-source", "none");
  await expect(page.locator("body")).toContainText("TikTok disconnected: the stored connection was deleted");
  await expect(disconnect).toHaveCount(0);
});
