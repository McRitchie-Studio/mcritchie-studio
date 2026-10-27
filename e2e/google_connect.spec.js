// [e2e] The Google connection, as an admin meets it: on /integrations, the
// Google Calendar, Gmail and Drive cards each carry Connect; connecting
// Calendar and then Drive comes back to /integrations each time with both
// connected (Google's incremental consent), and /admin/google proves each read.
// Disconnecting Drive keeps Calendar; disconnecting Calendar, the last, leaves
// every card on Connect. Connect Google asks for all three at once; a sign-in
// that unticks Gmail connects the other two, and a Gmail disconnected here
// stays off when Drive connects again, though Google echoes it back.
//
// WHAT THIS DOES NOT PROVE. Nothing here reaches Google: the lane's stand-in
// (config/initializers/google_connect_stand_in.rb) answers for Google's
// sign-in (granting the scopes each Connect asked for, or the subset a test
// unticks down to, and echoing past grants as include_granted_scopes does),
// its code exchange and the reads. The callback, the stored GoogleConnection and the pages are real.
// The exchange, refresh, revoke and reads are pinned in test/services/google_connect/.
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

const SCOPES = {
  calendar: "https://www.googleapis.com/auth/calendar.events.readonly",
  gmail: "https://www.googleapis.com/auth/gmail.readonly",
  // drive.file: only the files picked in the Google Picker (drive-files-you-pick).
  drive: "https://www.googleapis.com/auth/drive.file",
};
// The stand-in's code for a sign-in granting `scopes` (GoogleConnectStandIn.code_for).
const standInCode = (scopes) => "stand-in-code." + Buffer.from(scopes.join(" ")).toString("base64url");

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
  // A new Drive connection reads only picked files, and none are picked yet.
  await expect(section("drive").locator("[data-test='drive-read-kind']")).toHaveAttribute("data-kind", "picked");
  await expect(section("drive").locator("[data-test='google-read-item']")).toHaveCount(0);
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

const connectAll = (page) => page.locator("[data-test='google-connect-all']");
// While Gmail is missing, Connect Google (and Connect the rest) on /integrations
// opens the Gmail admin-trust modal first; its Continue goes on to Google.
const adminModal = (page) => page.locator("[data-test='gmail-admin-modal']");
const throughAdminModal = async (page, name) => {
  await connectAll(page).getByRole("button", { name }).click();
  await expect(adminModal(page)).toBeVisible();
  await adminModal(page).getByRole("link", { name: "Continue to Google" }).click();
};

test("an admin connects Calendar, Gmail and Drive at once with Connect Google", async ({ page }) => {
  // Every Disconnect asks to confirm. One standing handler accepts each, so a
  // confirm that never opens cannot leave a stray handler for the next one.
  page.on("dialog", (dialog) => dialog.accept());
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/integrations");
  const cards = { calendar: slot(page, "google_calendar"), gmail: slot(page, "gmail"), drive: slot(page, "google_drive") };
  await expect(connectAll(page)).toHaveAttribute("data-state", "none");

  await throughAdminModal(page, "Connect Google");
  await expect(page).toHaveURL(/\/integrations$/);
  await expect(page.getByText("Google Calendar, Gmail, and Google Drive connected for stand-in@example.com.")).toBeVisible();
  for (const card of Object.values(cards)) await expect(card).toHaveAttribute("data-state", "connected");
  await expect(connectAll(page)).toHaveAttribute("data-state", "all");
  await expect(connectAll(page).locator("[data-test='google-connect-all-status']")).toHaveText(/Google connected as\s+stand-in@example\.com/);
  await expect(connectAll(page).getByRole("link")).toHaveCount(0);
  // An admin's Google cards carry no contact-form Connect under Disconnect.
  for (const entry of ["google_calendar", "gmail", "google_drive"]) {
    await expect(page.locator(`[data-test='integration-entry'][data-entry='${entry}'] [data-test='entry-cta']`)).toHaveCount(0);
  }
  expect(await page.content()).not.toMatch(/stand-in-(refresh|access)/);

  await page.goto("/admin/google");
  await expect(connectAll(page)).toHaveAttribute("data-state", "all");
  for (const ability of ["calendar", "gmail", "drive"]) {
    await expect(page.locator(`[data-test='google-section'][data-ability='${ability}']`)).toHaveAttribute("data-state", "connected");
  }

  await page.goto("/integrations");
  for (const card of [cards.drive, cards.gmail, cards.calendar]) {
    await card.getByRole("button", { name: "Disconnect" }).click();
    await expect(card).toHaveAttribute("data-state", "none");
  }
  await expect(connectAll(page)).toHaveAttribute("data-state", "none");
});

test("a Connect Google that unticks Gmail connects the other two, and a disconnected Gmail stays off", async ({ page }) => {
  // Every Disconnect asks to confirm. One standing handler accepts each, so a
  // confirm that never opens cannot leave a stray handler for the next one.
  page.on("dialog", (dialog) => dialog.accept());
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/integrations");
  const cards = { calendar: slot(page, "google_calendar"), gmail: slot(page, "gmail"), drive: slot(page, "google_drive") };

  // Google's consent screen, with Gmail unticked: the sign-in comes back with a
  // code granting the other two.
  await connectAll(page).getByRole("button", { name: "Connect Google" }).click();
  const href = await adminModal(page).getByRole("link", { name: "Continue to Google" }).getAttribute("href");
  const toGoogle = await page.request.get(href, { maxRedirects: 0 });
  expect(toGoogle.status()).toBe(302);
  const back = new URL(toGoogle.headers()["location"]);
  const asked = Buffer.from(back.searchParams.get("code").replace("stand-in-code.", ""), "base64url").toString().split(" ");
  expect(asked).toEqual(["openid", "email", SCOPES.calendar, SCOPES.gmail, SCOPES.drive]);
  back.searchParams.set("code", standInCode(asked.filter((scope) => scope !== SCOPES.gmail)));
  await page.goto(back.toString());

  await expect(page).toHaveURL(/\/integrations$/);
  await expect(page.getByText("Google Calendar and Google Drive connected for stand-in@example.com. Gmail was left unticked, so it stays off.")).toBeVisible();
  await expect(cards.calendar).toHaveAttribute("data-state", "connected");
  await expect(cards.drive).toHaveAttribute("data-state", "connected");
  await expect(cards.gmail).toHaveAttribute("data-state", "none");
  await expect(connectAll(page)).toHaveAttribute("data-state", "some");

  // Connect the rest grants Gmail too.
  await throughAdminModal(page, "Connect the rest");
  await expect(cards.gmail).toHaveAttribute("data-state", "connected");
  await expect(connectAll(page)).toHaveAttribute("data-state", "all");

  // Disconnect Gmail and Drive here; Google still holds both. Connecting Drive
  // again echoes Gmail back, and Gmail stays off.
  for (const card of [cards.gmail, cards.drive]) {
    await card.getByRole("button", { name: "Disconnect" }).click();
    await expect(card).toHaveAttribute("data-state", "none");
  }
  await cards.drive.getByRole("link", { name: "Connect Google Drive" }).click();
  await expect(page.getByText("Google Drive connected for stand-in@example.com.")).toBeVisible();
  await expect(cards.drive).toHaveAttribute("data-state", "connected");
  await expect(cards.gmail).toHaveAttribute("data-state", "none");

  for (const card of [cards.drive, cards.calendar]) {
    await card.getByRole("button", { name: "Disconnect" }).click();
    await expect(card).toHaveAttribute("data-state", "none");
  }
});
