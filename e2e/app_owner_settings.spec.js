// [e2e] An app owner sets their CTO's daily report channel (docs/agents/system/app-owners.md).
// owner@turf.test is a plain viewer who owns Turf Monster: signed in, the sidebar
// names the app and its CTO ("Turf"); the CTO's settings page offers the shared
// bot's postable channels; they pick #cto-reports, save, and the choice persists.
// Another app's page is a 404. At phone width nothing runs off the side.
//
// NOT @qa-readonly: it writes the cto_report:turf_monster report_destinations row,
// against rows e2e/seed.rb owns. Nothing here talks to Discord.
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink, VISITOR } = require("./helpers");

test.use({ storageState: VISITOR });

const setting = (page) => page.locator("[data-test='agent-report-setting']");

test("an owner picks the daily report channel for Turf and the choice persists", async ({ page }) => {
  await loginWithMagicLink(page, "owner@turf.test");

  await page.goto("/applications/turf-monster");
  await expect(page.getByRole("heading", { name: "Turf Monster", level: 1 })).toBeVisible();
  const sidebar = page.locator("#studio-link-sidebar");
  await expect(sidebar.locator("a[href='/applications/turf-monster']")).toHaveCount(1);
  await expect(sidebar.locator("a[href='/agents/turf-monster/settings']")).toContainText("Turf");

  await page.locator("[data-test='application-cto-settings']").click();
  await expect(page.getByRole("heading", { name: "Turf", level: 1 })).toBeVisible();
  await expect(setting(page)).toHaveAttribute("data-state", "not_configured");

  const select = setting(page).locator("[data-test='agent-report-channel']");
  const labels = await select.locator("option").allTextContents();
  expect(labels).toEqual(["No channel", "#general", "#cto-reports", "#announcements"]);

  await select.selectOption({ label: "#cto-reports" });
  await setting(page).getByRole("button", { name: "Save" }).click();

  await expect(page.locator("body")).toContainText("Daily report: #cto-reports, on.");
  await expect(setting(page)).toHaveAttribute("data-state", "on");
  await page.reload();
  await expect(select.locator("option:checked")).toHaveText("#cto-reports");

  await page.setViewportSize({ width: 390, height: 844 });
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
  expect(overflow, "nothing runs off the side at 390px").toBeLessThanOrEqual(0);

  const other = await page.request.get("/applications/cyvasse", { maxRedirects: 0 });
  expect(other.status(), "another app's page does not exist for this owner").toBe(404);
});
