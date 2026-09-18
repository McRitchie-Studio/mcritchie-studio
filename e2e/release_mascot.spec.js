const { test, expect } = require("@playwright/test");
const { openDeploySidebar } = require("./helpers");

// The /deployments release cards wear the conductor SESSION's Pokémon mascot and a
// timing line — "in progress · <dur>" while a release is active, "took <dur>" once
// it ships — so the board shows the deployment is being worked on by an agent and
// how long it has taken. Seeded (e2e/seed.rb): an ACTIVE Next Release (Snorlax) and
// a SHIPPED Last Release (Dragonite, ~18m). Happy-path render only.
test("the deployments release cards show the conductor mascot + timing", async ({ page }) => {
  await page.goto("/deployments");

  // The SUMMARY card says who ran the last deploy without a click — the operator's spec:
  // "the time of last release and the pokemon that ran it".
  await expect(page.locator("#release-summary-card [data-test='release-summary-last-mascot']")).toContainText("Dragonite");
  await expect(page.locator("#release-summary-card [data-test='release-summary-last-shipped'] time")).toBeVisible();

  // The full cards live in the Releases sidebar; the summary card opens it.
  await openDeploySidebar(page, "releases");

  // Next Release (active) — its conductor's mascot + a live in-progress timer.
  const next = page.locator("#current-release [data-test='release-mascot']");
  await expect(next).toContainText("Snorlax");
  await expect(next.locator("img")).toBeVisible();
  await expect(page.locator("#current-release [data-test='release-timing']")).toContainText("in progress");

  // Last Release (shipped) — the mascot of whoever ran the deploy + the total it took.
  const last = page.locator("#last-release [data-test='release-mascot']");
  await expect(last).toContainText("Dragonite");
  await expect(last.locator("img")).toBeVisible();
  await expect(page.locator("#last-release [data-test='release-timing']")).toContainText("took");
});
