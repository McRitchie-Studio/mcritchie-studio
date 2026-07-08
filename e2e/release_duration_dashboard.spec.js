const { test, expect } = require("@playwright/test");
const { execFileSync } = require("node:child_process");

function seedPaginationReleases() {
  const script = `
    base_time = Time.zone.parse("2020-01-01 12:00:00")
    Release.where("slug LIKE ?", "rel-e2e-page-%").destroy_all
    26.times do |index|
      release = Release.create!(slug: "rel-e2e-page-#{format('%02d', index + 1)}", branch: "release", state: "shipped")
      release.update_columns(created_at: base_time + index.minutes, shipped_at: base_time + index.minutes, updated_at: base_time + index.minutes)
    end
  `;
  execFileSync("bin/rails", ["runner", script], {
    env: { ...process.env, RAILS_ENV: "test" },
    stdio: "inherit",
  });
}

test("deployments analytics card navigates to release history and detail", async ({ page }) => {
  seedPaginationReleases();
  const pageErrors = [];
  page.on("pageerror", (err) => pageErrors.push(String(err)));
  page.on("console", (msg) => { if (msg.type() === "error") pageErrors.push(msg.text()); });

  await page.goto("/deployments");

  const card = page.locator("#release-duration-card");
  await expect(card).toBeVisible();
  await expect(card.locator("[data-test='release-duration-stage']")).toHaveCount(5);
  await expect(
    card.locator("[data-test='release-duration-stage'][data-stage='deployed']"),
  ).toContainText("Deployed");
  await expect(
    card.locator("[data-test='release-duration-stage'][data-stage='total']"),
  ).toContainText("Total");

  await card.getByRole("link", { name: "All Deployments" }).click();
  await expect(page).toHaveURL(/\/deployments\/all$/);
  await expect(page.getByRole("heading", { name: "All Deployments" })).toBeVisible();
  // 25 release rows + the 2 pinned running-average rows (3-release / 10-release).
  await expect(page.locator("table tbody tr")).toHaveCount(27);
  await expect(page.locator("tbody tr[data-test='deployment-average-row']")).toHaveCount(2);
  await expect(page.getByText(/Page 1 \//)).toBeVisible();

  await page.getByRole("link", { name: "Next" }).click();
  await expect(page).toHaveURL(/\/deployments\/all\?page=2$/);
  await expect(page.getByRole("link", { name: "Previous" })).toBeVisible();
  await expect(page.getByRole("link", { name: "rel-e2e-page-01" })).toBeVisible();

  const releaseLink = page.locator("table tbody a[href^='/deployments/']").first();
  const releaseSlug = (await releaseLink.textContent()).trim();
  await releaseLink.click();

  await expect(page).toHaveURL(new RegExp(`/deployments/${releaseSlug}$`));
  await expect(page.getByRole("heading", { name: releaseSlug })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Stage Averages" })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Member Tasks" })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Release Steps" })).toBeVisible();

  expect(pageErrors, pageErrors.join("\n")).toHaveLength(0);
});
