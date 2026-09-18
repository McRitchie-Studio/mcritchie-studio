const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

// /communications — the communications record.
//
// WHY A BROWSER TIER EARNS ITS PLACE HERE. The model tier proves the scopes and
// the component tier proves the markup those scopes produce. Neither loads the
// real page: the filter row is a dozen link_to calls that each rebuild the query
// string from the OTHER three filters, and a single dropped parameter there
// means a filter silently clears its siblings — every server-side test still
// passes, because each one asks for one filter at a time. So this walks the
// filters the way an operator does, by clicking them, and checks the ones it did
// not click survive.
//
// NOT TAGGED @qa-readonly ON PURPOSE. That tag makes prod-smoke run a spec
// against PRODUCTION, where these seeded rows do not exist, and a seed-fixture
// assertion there red-seals every ship. This spec owns its data, so it is an
// ordinary chromium spec.

const rows = (page) => page.locator("#comm-rows tbody tr");

test("asks sort above the raw stream, and each filter narrows without clearing the others", async ({ page }) => {
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/communications");

  await expect(page.getByRole("heading", { name: "Communications" })).toBeVisible();

  // ORDER: both asks first, then the general rows newest-first.
  const kinds = await rows(page).evaluateAll((els) => els.map((el) => el.dataset.kind));
  expect(kinds.length).toBeGreaterThanOrEqual(5);
  const firstGeneral = kinds.indexOf("general");
  expect(firstGeneral).toBeGreaterThan(0);
  expect(kinds.slice(0, firstGeneral).every((k) => k === "ask")).toBe(true);
  expect(kinds.slice(firstGeneral).every((k) => k === "general")).toBe(true);

  // The newest ask leads.
  await expect(rows(page).first()).toContainText("draft a reply about the revised schedule");

  // A privileged row is NAMED and its body is not on the page.
  await expect(page.locator("#comm-rows")).toContainText("privileged");
  await expect(page.locator("body")).not.toContainText("e2e-privileged-body-marker");

  // FILTER 1 — kind. Click it like an operator, not by typing a URL.
  await page.locator("#comm-filters").getByRole("link", { name: /^ask \(/ }).click();
  await expect(page).toHaveURL(/kind=ask/);
  let filtered = await rows(page).evaluateAll((els) => els.map((el) => el.dataset.kind));
  expect(filtered.length).toBe(2);
  expect(filtered.every((k) => k === "ask")).toBe(true);

  // FILTER 2 — status, ON TOP of kind. This is the assertion the server-side
  // tiers cannot make: that clicking the second filter kept the first.
  await page.locator("#comm-filters").getByRole("link", { name: "delivered", exact: true }).click();
  await expect(page).toHaveURL(/kind=ask/);
  await expect(page).toHaveURL(/status=delivered/);
  await expect(rows(page)).toHaveCount(1);
  await expect(rows(page).first()).toContainText("appraisal summary");

  // The deliverable is a LINK a human opens — the terminal state of every
  // pipeline that will write into this table.
  const draft = rows(page).first().getByRole("link", { name: "open draft" });
  await expect(draft).toHaveAttribute("href", /compose=e2edraft/);

  // FILTER 3 — entity, on top of both.
  await page.locator("#comm-filters").getByRole("link", { name: "e2e-entity", exact: true }).click();
  await expect(page).toHaveURL(/kind=ask/);
  await expect(page).toHaveURL(/status=delivered/);
  await expect(page).toHaveURL(/entity=e2e-entity/);
  await expect(rows(page)).toHaveCount(1);

  // And a filter with nothing behind it says so rather than showing a bare table.
  await page.goto("/communications?channel=pocket");
  await expect(page.locator("#comm-empty")).toContainText("Nothing recorded yet");
  await expect(page.locator("#comm-rows")).toHaveCount(0);
});
