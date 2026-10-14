// [e2e] The Google Calendar connection, as an admin meets it: Connect comes
// back to the standing page, which names the account, lists the next week's
// events and shows no token. Disconnect asks first, then deletes the stored
// connection and the page says not connected.
//
// WHAT THIS DOES NOT PROVE. Nothing here reaches Google: the lane's stand-in
// (config/initializers/google_calendar_stand_in.rb) answers for Google's
// sign-in, its code exchange and the events read. The callback, the stored
// GoogleCalendarConnection and the page are real. The exchange, refresh,
// revoke and read are pinned in test/services/google_calendar/oauth_client_test.rb.
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

test("an admin connects Google Calendar, sees the week and no token, then disconnects", async ({ page }) => {
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/admin/google_calendar");
  const panel = page.locator("[data-test='google-calendar-connection']");
  await expect(panel).toHaveAttribute("data-source", "none");

  await panel.getByRole("link", { name: "Connect Google Calendar" }).click();
  await expect(page).toHaveURL(/\/admin\/google_calendar$/);
  await expect(panel).toHaveAttribute("data-source", "connected");
  await expect(page.getByText("Google Calendar connected for stand-in@example.com.")).toBeVisible();
  await expect(panel.locator("[data-field='account']")).toHaveText("stand-in@example.com");
  await expect(panel.locator("[data-test='google-calendar-event']")).toHaveCount(2);
  await expect(panel.locator("[data-test='google-calendar-event']").first()).toContainText("Stand-in: lender call");

  const html = await page.content();
  expect(html).not.toMatch(/stand-in-(refresh|access)/);

  page.once("dialog", (dialog) => dialog.accept());
  await panel.getByRole("button", { name: "Disconnect" }).click();
  await expect(panel).toHaveAttribute("data-source", "none");
  await expect(page.getByText("Google Calendar disconnected: deleted here and revoked at Google.")).toBeVisible();
});

// The same connection from the public /integrations page, as an admin meets
// it on the Google Workspace card's "Sign in" row: Connect comes back to
// /integrations naming the account, and Disconnect asks first, then comes
// back to /integrations with the Connect button again.
test("an admin connects from the integrations card, sees the account, then disconnects there", async ({ page }) => {
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/integrations");
  const row = page.locator("[data-test='integration-entry'][data-entry='google_workspace_connect'] [data-test='entry-method'][data-method='sign_in']");
  const slot = row.locator("[data-test='calendar-connection']");
  await expect(slot).toHaveAttribute("data-state", "none");

  await slot.getByRole("link", { name: "Connect Google Calendar" }).click();
  await expect(page).toHaveURL(/\/integrations$/);
  await expect(page.getByText("Google Calendar connected for stand-in@example.com.")).toBeVisible();
  await expect(slot).toHaveAttribute("data-state", "connected");
  await expect(slot.locator("[data-test='calendar-account']")).toHaveText(/Connected as\s+stand-in@example\.com/);
  expect(await page.content()).not.toMatch(/stand-in-(refresh|access)/);

  page.once("dialog", (dialog) => dialog.accept());
  await slot.getByRole("button", { name: "Disconnect" }).click();
  await expect(page).toHaveURL(/\/integrations$/);
  await expect(slot).toHaveAttribute("data-state", "none");
  await expect(slot.getByRole("link", { name: "Connect Google Calendar" })).toBeVisible();
});
