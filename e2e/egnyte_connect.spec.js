// [e2e] The Egnyte connection, as an admin meets it: on /integrations the
// Egnyte card (in the Connect group, Coming soon for clients) carries a domain
// field and Connect Egnyte; connecting comes back to /integrations with the
// domain connected, and /admin/egnyte proves the read: the Shared root's
// folders and file, and a subfolder one click in. The stand-in's access tokens
// live inside the refresh margin, so every load refreshes: loading the page
// twice proves the rotated refresh token was stored (the stand-in honours only
// the last one it issued). Disconnect revokes and deletes the connection.
//
// WHAT THIS DOES NOT PROVE. Nothing here reaches Egnyte: the lane's stand-in
// (config/initializers/egnyte_connect_stand_in.rb) answers for Egnyte's
// sign-in page, its token and revoke endpoints and the reads. The callback,
// the code exchange and refresh code, the stored EgnyteConnection and the
// pages are real. The real request shapes are pinned in test/services/egnyte/.
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

test("admin connects an Egnyte domain with the stand-in, browses it, then disconnects", async ({ page }) => {
  page.on("dialog", (dialog) => dialog.accept());
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/integrations");
  const card = page.locator("[data-test='integration-group'][data-group='connect'] [data-test='integration-entry'][data-entry='egnyte']");
  const slot = card.locator("[data-test='entry-action'] [data-test='egnyte-connection']");
  await expect(slot).toHaveAttribute("data-state", "none");
  await expect(card.locator("[data-test='coming-soon']")).toBeVisible();
  await expect(card.locator("[data-test='entry-cta']")).toHaveCount(0);

  await slot.locator("[data-test='egnyte-domain-field']").fill("Standin.egnyte.com");
  await slot.getByRole("button", { name: "Connect Egnyte" }).click();
  await expect(page).toHaveURL(/\/integrations$/);
  await expect(page.getByText("Egnyte connected: standin.egnyte.com as stand.in.")).toBeVisible();
  await expect(slot).toHaveAttribute("data-state", "connected");
  await expect(slot.locator("[data-test='egnyte-domain'][data-domain='standin']")).toContainText("standin.egnyte.com");
  expect(await page.content()).not.toMatch(/stand-in-(refresh|access)/);

  const section = page.locator("[data-test='egnyte-section'][data-domain='standin']");
  for (const load of [1, 2]) {
    await page.goto("/admin/egnyte");
    await expect(section, `load ${load}`).toHaveAttribute("data-state", "connected");
    const read = section.locator("[data-test='egnyte-read']");
    await expect(read).toHaveAttribute("data-path", "/Shared");
    await expect(read).toHaveAttribute("data-folders", "2");
    await expect(read).toHaveAttribute("data-files", "1");
    await expect(section.locator("[data-field='refreshed']")).toBeVisible();
    expect(await page.content()).not.toMatch(/stand-in-(refresh|access)/);
  }

  await section.getByRole("link", { name: /Projects/ }).click();
  await expect(section.locator("[data-test='egnyte-read']")).toHaveAttribute("data-path", "/Shared/Projects");
  await expect(section.locator("[data-test='egnyte-file']")).toContainText("Plan.pdf");

  await section.getByRole("button", { name: "Disconnect" }).click();
  await expect(page.getByText("tokens were revoked on Egnyte and deleted here", { exact: false })).toBeVisible();
  await expect(page.locator("[data-test='egnyte-section'][data-state='none']")).toBeVisible();

  await page.goto("/integrations");
  await expect(slot).toHaveAttribute("data-state", "none");
});
