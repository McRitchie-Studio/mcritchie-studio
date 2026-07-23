const { test, expect } = require("@playwright/test");

// [e2e] The per-application release-inclusion marker on the Deploy board's `reviewed`
// stage — Avi's qa-release disposition made board-visible. Shipping is the DEFAULT, so
// a reviewed member riding the next candidate carries NO marker (the green "IN RELEASE"
// bar was dropped as noise); only an app Avi held back (included_in_release:false) wears
// the amber HELD FROM RELEASE marker naming its app. Read-only against the seeded
// e2e-release-inclusion-* fixtures on /deployments.
test("reviewed cards show the release-inclusion marker only for a HELD member", async ({ page }) => {
  const res = await page.goto("/deployments");
  expect(res.ok()).toBe(true);

  // The default member rides — no marker at all (shipping every reviewed task is the default).
  const included = page.locator("#card-e2e-release-inclusion-in-demo");
  await expect(included).toBeVisible();
  await expect(included.locator("[data-test='release-inclusion-marker']")).toHaveCount(0);
  await expect(included.locator("[data-test='release-inclusion-in']")).toHaveCount(0);

  // The held-back member — the amber HELD FROM RELEASE bar, naming its app.
  const held = page.locator("#card-e2e-release-inclusion-held-demo");
  await expect(held).toBeVisible();
  const heldBar = held.locator("[data-test='release-inclusion-held']");
  await expect(heldBar).toBeVisible();
  await expect(heldBar).toContainText("HELD FROM RELEASE");
  await expect(heldBar).toContainText("mcritchie-studio");
  await expect(held.locator("[data-test='release-inclusion-in']")).toHaveCount(0);
});
