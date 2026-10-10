// [e2e] The TikTok sign-in, as an admin meets it: /admin/tiktok/connect comes
// back to a page that says the connection is saved, names the account, the
// scope and the day the refresh token expires, and shows no token. Nothing on
// it is to be copied anywhere. Its Disconnect button asks first, then deletes
// the stored connection and lands on the standing page, /admin/tiktok.
//
// WHAT THIS DOES NOT PROVE. Nothing here reaches TikTok: the lane's stand-in
// (config/initializers/tiktok_draft_stand_in.rb, SignIn) answers for TikTok's
// authorize page and its code exchange with values that start "stand-in-".
// The callback, the stored connection and the page are real. The exchange with
// TikTok itself, the token source and rotation are pinned in
// test/services/tiktok/oauth_client_token_source_test.rb.
const fs = require("fs");
const path = require("path");
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

test("an admin connects TikTok and the page shows a saved connection and no token", async ({ page }, testInfo) => {
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/admin/tiktok/connect");

  await expect(page).toHaveURL(/\/admin\/tiktok\/callback\?/);
  const connected = page.locator("[data-tiktok-connected]");
  await expect(connected.getByRole("heading", { level: 1 })).toHaveText("TikTok connected and saved");
  // The control for the absence below: a value from the same answer IS on the page.
  await expect(connected.locator("[data-tiktok-field='account']")).toHaveText("stand-in-account");
  await expect(connected.locator("[data-tiktok-field='scope']")).toContainText("video.upload");
  await expect(connected.locator("[data-tiktok-field='refresh-expires']")).toContainText(/\b20\d\d\b/);

  const html = await page.content();
  expect(html).not.toMatch(/stand-in-(refresh|access)/);
  expect(html).not.toMatch(/TIKTOK_REFRESH_TOKEN|TIKTOK_OPEN_ID/);
  await expect(page.locator("main pre, [data-tiktok-connected] pre")).toHaveCount(0);

  const shots = process.env.TIKTOK_CONNECT_SHOTS;
  if (shots) {
    fs.mkdirSync(shots, { recursive: true });
    await page.screenshot({ path: path.join(shots, `callback-connected-${testInfo.project.name}.png`), fullPage: true });
  }

  // Signing the same account in again lands on the same page: one connection, updated.
  await page.goto("/admin/tiktok/connect");
  await expect(connected.locator("[data-tiktok-field='account']")).toHaveText("stand-in-account");

  // Disconnect asks first. Declined, the connection stays; accepted, it is
  // deleted and the page says what the server falls back to.
  page.once("dialog", (dialog) => dialog.dismiss());
  await connected.getByRole("button", { name: "Disconnect TikTok" }).click();
  await expect(connected.locator("[data-tiktok-field='account']")).toHaveText("stand-in-account");

  let asked = "";
  page.once("dialog", (dialog) => { asked = dialog.message(); dialog.accept(); });
  await connected.getByRole("button", { name: "Disconnect TikTok" }).click();
  // It lands on the standing connection page, which now says not connected.
  await expect(page).toHaveURL(/\/admin\/tiktok$/);
  await expect(page.locator("[data-test='tiktok-connection']")).toHaveAttribute("data-source", "none");
  expect(asked).toContain("Delete the stored TikTok connection");
  await expect(page.getByText("TikTok disconnected: the stored connection was deleted from this server.", { exact: false })).toBeVisible();
  await expect(page.getByText(/Drafting is (off|still on):/)).toBeVisible();
});
