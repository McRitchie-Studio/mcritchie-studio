const { test, expect } = require("@playwright/test");
const { watchPageErrors } = require("./helpers");

// Pagination fixture (the 26 rel-e2e-page-* shipped releases) lives in e2e/seed.rb
// with every other spec's data. It USED to be seeded right here via a synchronous
// `bin/rails runner` — a full Rails boot inside this test's own 30s clock, eating
// 17-26s of it and starving the clicks below of retry headroom under load
// (run 29707557195, shard 2). Never seed inside the test clock.
test("deployments analytics card navigates to release history and detail", async ({ page }) => {
  const { pageErrors, report } = watchPageErrors(page);

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

  // Navbar-safe click. The card sits at the bottom of the board under the app's
  // sticky top navbar (z-50, layouts/application.html.erb): Playwright's minimal
  // auto-scroll can park the link at the very top edge, UNDER the navbar, and the
  // header subtree then intercepts pointer events on every retry until timeout.
  // Centering the link in the viewport first makes the geometry deterministic.
  const allDeploymentsLink = card.getByRole("link", { name: "All Deployments" });
  await allDeploymentsLink.evaluate((el) => el.scrollIntoView({ block: "center", behavior: "instant" }));
  await allDeploymentsLink.click();
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

  expect(pageErrors, report()).toHaveLength(0);
});
