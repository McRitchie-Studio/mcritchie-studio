// [e2e] The Google connection, as an admin meets it: on /integrations, the
// Google Calendar, Gmail and Drive cards each carry Connect; connecting
// Calendar and then Drive comes back to /integrations each time with both
// connected (Google's incremental consent), and /admin/google proves each read.
// Disconnecting Drive keeps Calendar; disconnecting Calendar, the last, leaves
// every card on Connect.
//
// WHAT THIS DOES NOT PROVE. Nothing here reaches Google: the lane's stand-in
// (config/initializers/google_connect_stand_in.rb) answers for Google's
// sign-in (granting the scope each Connect asked for), its code exchange and
// the reads. The callback, the stored GoogleConnection and the pages are real.
// The exchange, refresh, revoke and reads are pinned in test/services/google_connect/.
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

const slot = (page, entry) =>
  page.locator(`[data-test='integration-entry'][data-entry='${entry}'] [data-test='entry-method'][data-method='sign_in'] [data-test='google-connection']`);

test("an admin connects Calendar then Drive from the integrations cards, sees each read, then disconnects them", async ({ page }) => {
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/integrations");
  const calendar = slot(page, "google_calendar");
  const gmail = slot(page, "gmail");
  const drive = slot(page, "google_drive");
  for (const card of [calendar, gmail, drive]) await expect(card).toHaveAttribute("data-state", "none");

  await calendar.getByRole("link", { name: "Connect Google Calendar" }).click();
  await expect(page).toHaveURL(/\/integrations$/);
  await expect(page.getByText("Google Calendar connected for stand-in@example.com.")).toBeVisible();
  await expect(calendar).toHaveAttribute("data-state", "connected");
  await expect(calendar.locator("[data-test='google-account']")).toHaveText(/Connected as\s+stand-in@example\.com/);
  await expect(drive).toHaveAttribute("data-state", "none");

  await drive.getByRole("link", { name: "Connect Google Drive" }).click();
  await expect(page).toHaveURL(/\/integrations$/);
  await expect(page.getByText("Google Drive connected for stand-in@example.com.")).toBeVisible();
  await expect(drive).toHaveAttribute("data-state", "connected");
  await expect(calendar).toHaveAttribute("data-state", "connected"); // Drive did not replace Calendar
  await expect(gmail).toHaveAttribute("data-state", "none");
  expect(await page.content()).not.toMatch(/stand-in-(refresh|access)/);

  await page.goto("/admin/google");
  const section = (ability) => page.locator(`[data-test='google-section'][data-ability='${ability}']`);
  await expect(section("calendar")).toHaveAttribute("data-state", "connected");
  await expect(section("calendar").locator("[data-test='google-read-item']").first()).toContainText("Stand-in: lender call");
  await expect(section("drive")).toHaveAttribute("data-state", "connected");
  await expect(section("drive").locator("[data-test='google-read-item']")).toHaveCount(3);
  await expect(section("gmail")).toHaveAttribute("data-state", "none");
  expect(await page.content()).not.toMatch(/stand-in-(refresh|access)/);

  await page.goto("/integrations");
  page.once("dialog", (dialog) => dialog.accept());
  await drive.getByRole("button", { name: "Disconnect" }).click();
  await expect(page.getByText("Google Drive disconnected here. The account's other Google connections stay.")).toBeVisible();
  await expect(drive).toHaveAttribute("data-state", "none");
  await expect(calendar).toHaveAttribute("data-state", "connected");

  page.once("dialog", (dialog) => dialog.accept());
  await calendar.getByRole("button", { name: "Disconnect" }).click();
  await expect(page.getByText("Google Calendar disconnected: deleted here and revoked at Google.")).toBeVisible();
  await expect(page).toHaveURL(/\/integrations$/);
  for (const card of [calendar, gmail, drive]) await expect(card).toHaveAttribute("data-state", "none");
});

test("the Gmail read shows on the admin page after connecting it there", async ({ page }) => {
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/admin/google");
  const gmail = page.locator("[data-test='google-section'][data-ability='gmail']");
  await expect(gmail).toHaveAttribute("data-state", "none");

  await gmail.getByRole("link", { name: "Connect Gmail" }).click();
  await expect(page).toHaveURL(/\/admin\/google$/);
  await expect(gmail).toHaveAttribute("data-state", "connected");
  await expect(gmail.locator("[data-test='google-read-item']")).toHaveCount(3);
  await expect(gmail.locator("[data-test='google-read-item']").first()).toContainText("Stand-in: message 1");

  page.once("dialog", (dialog) => dialog.accept());
  await gmail.getByRole("button", { name: "Disconnect" }).click();
  await expect(gmail).toHaveAttribute("data-state", "none");
});
