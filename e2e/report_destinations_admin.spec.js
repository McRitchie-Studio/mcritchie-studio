// [e2e] /admin/report_destinations, the way Alex meets it: daily_app_report has
// no channel; the select offers only postable, unarchived channels, grouped by
// category; he picks #cto-reports and saves; the card says it posts there, and
// the choice survives a reload. At phone width nothing runs off the side.
//
// NOT @qa-readonly: it writes a report_destinations row, against rows e2e/seed.rb
// owns. Nothing here talks to Discord (no Refresh, no delivery).
const { test, expect } = require("@playwright/test");

const card = (page) => page.locator("[data-test='report-destination'][data-report-key='daily_app_report']");

test("pick a channel for daily_app_report and the choice persists", async ({ page }) => {
  await page.goto("/admin/report_destinations");
  await expect(page.getByRole("heading", { name: "Report destinations" })).toBeVisible();
  await expect(card(page)).toHaveAttribute("data-state", "not_configured");

  const select = card(page).locator("[data-test='destination-channel']");
  const labels = await select.locator("option").allTextContents();
  expect(labels).toEqual(["No channel", "#general", "#cto-reports", "#announcements"]);
  await expect(select.locator("optgroup[label='Ops'] option")).toHaveCount(2);

  await select.selectOption({ label: "#cto-reports" });
  await card(page).getByRole("button", { name: "Save" }).click();

  await expect(page.locator("body")).toContainText("Daily application report: #cto-reports, on.");
  await expect(card(page)).toHaveAttribute("data-state", "on");
  await expect(card(page).locator("[data-test='destination-badge']")).toHaveText("Posting to #cto-reports");

  await page.reload();
  await expect(card(page).locator("[data-test='destination-channel'] option:checked")).toHaveText("#cto-reports");

  await page.setViewportSize({ width: 390, height: 844 });
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
  expect(overflow, "nothing runs off the side at 390px").toBeLessThanOrEqual(0);
});
