// [e2e] An admin connects an Egnyte domain from the dark /integrations card,
// browses /admin/egnyte twice (the stand-in's tokens live inside the refresh
// margin and it honours only its last refresh token, so the second load proves
// the rotated pair was stored), opens a subfolder, then disconnects.
// NOT PROVEN: nothing reaches Egnyte; config/initializers/egnyte_connect_stand_in.rb
// answers its sign-in, token, revoke and read endpoints. The callback, the
// exchange and refresh code, the row and the pages are real; the request
// shapes are pinned in test/services/egnyte/.
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
