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
  // Each half is ONE line — label, when, how long — with the conductor's sprite floated
  // to its right end; the name rides with it (shown when the card has room, and in the
  // title when it does not).
  const summary = page.locator("#release-summary-card");
  await expect(summary.locator("[data-test='release-summary-last-mascot']")).toContainText("Dragonite");
  await expect(summary.locator("[data-test='release-summary-last-mascot-conductor'] img")).toBeVisible();
  await expect(summary.locator("[data-test='release-summary-last-shipped'] time")).toBeVisible();
  await expect(summary.locator("[data-test='release-summary-next-mascot']")).toContainText("Snorlax");
  await expect(summary.locator("[data-test='release-summary-next-mascot-conductor'] img")).toBeVisible();
  // The open candidate's apps, each an unlabelled stage tracker — four pills, named for
  // assistive tech.
  const tracker = summary.locator("[data-test='release-app-tracker']").first();
  await expect(tracker).toBeVisible();
  await expect(tracker.locator("[data-test='release-app-tracker-segment']")).toHaveCount(4);
  await expect(tracker).toHaveAttribute("aria-label", /stages done/);

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
