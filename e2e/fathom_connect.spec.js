// [e2e] The Fathom connection, as an admin meets it: on /integrations the
// Fathom card (Meeting notes) carries Connect Fathom; connecting comes back to
// /integrations connected as the account Fathom names, and /admin/fathom proves
// the read: the first page of meetings, the newest meeting's title, its
// transcript's lines and speakers and its summary. Loading the page twice
// proves the single-use refresh token rotated: the stand-in honours only the
// last refresh token it issued, so a refresh that did not store its new token
// would fail the second load. Disconnect deletes the connection.
//
// WHAT THIS DOES NOT PROVE. Nothing here reaches Fathom: the lane's stand-in
// (config/initializers/fathom_connect_stand_in.rb) answers for Fathom's
// sign-in page, its token endpoint and the reads. The callback, the code
// exchange and refresh code, the stored FathomConnection and the pages are
// real. The real request shapes are pinned in test/services/fathom/.
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

test("admin connects Fathom with the stand-in and sees the newest meeting", async ({ page }) => {
  page.on("dialog", (dialog) => dialog.accept());
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/integrations");
  const card = page.locator("[data-test='integration-group'][data-group='meeting_notes'] [data-test='integration-entry'][data-entry='fathom']");
  const slot = card.locator("[data-test='entry-method'][data-method='sign_in'] [data-test='fathom-connection']");
  await expect(slot).toHaveAttribute("data-state", "none");
  await expect(card.locator("[data-test='entry-cta']")).toHaveCount(0);

  await slot.getByRole("link", { name: "Connect Fathom" }).click();
  await expect(page).toHaveURL(/\/integrations$/);
  await expect(page.getByText("Fathom connected for stand-in@example.com.")).toBeVisible();
  await expect(slot).toHaveAttribute("data-state", "connected");
  await expect(slot.locator("[data-test='fathom-account']")).toHaveText(/Connected as\s+stand-in@example\.com/);
  expect(await page.content()).not.toMatch(/stand-in-(refresh|access)/);

  const section = page.locator("[data-test='fathom-section']");
  for (const load of [1, 2]) {
    await page.goto("/admin/fathom");
    await expect(section, `load ${load}`).toHaveAttribute("data-state", "connected");
    await expect(section.locator("[data-test='fathom-read']")).toHaveAttribute("data-count", "2");
    await expect(section.locator("[data-test='fathom-read']")).toHaveAttribute("data-more", "true");
    await expect(section.locator("[data-field='newest-title']")).toHaveText("Stand-in: lender call");
    await expect(section.locator("[data-field='transcript']")).toHaveAttribute("data-lines", "3");
    await expect(section.locator("[data-field='transcript']")).toHaveAttribute("data-speakers", "2");
    await expect(section.locator("[data-field='summary']")).not.toHaveAttribute("data-length", "0");
    await expect(section.locator("[data-field='refreshed']")).toBeVisible();
    expect(await page.content()).not.toMatch(/stand-in-(refresh|access)/);
  }

  await section.getByRole("button", { name: "Disconnect" }).click();
  await expect(page.getByText("Fathom disconnected: the stored token was deleted here.", { exact: false })).toBeVisible();
  await expect(section).toHaveAttribute("data-state", "none");
  await expect(section.getByRole("link", { name: "Connect Fathom" })).toBeVisible();

  await page.goto("/integrations");
  await expect(slot).toHaveAttribute("data-state", "none");
});
