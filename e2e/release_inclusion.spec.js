const { test, expect } = require("@playwright/test");

// [e2e] The per-application release-inclusion marker on the Deploy board's `reviewed`
// stage — Avi's qa-release disposition made board-visible. A reviewed member riding the
// next candidate (the default) shows the green IN RELEASE marker; one Avi held back
// (included_in_release:false) shows the amber HELD FROM RELEASE marker naming its app.
// Read-only against the seeded e2e-release-inclusion-* fixtures on /deployments.
test("reviewed cards show the per-app release-inclusion marker", async ({ page }) => {
  const res = await page.goto("/deployments");
  expect(res.ok()).toBe(true);

  // The default member rides — green IN RELEASE, naming its app.
  const included = page.locator("#card-e2e-release-inclusion-in-demo");
  await expect(included).toBeVisible();
  const inBar = included.locator("[data-test='release-inclusion-in']");
  await expect(inBar).toBeVisible();
  await expect(inBar).toContainText("IN RELEASE");
  await expect(inBar).toContainText("turf-monster");
  await expect(included.locator("[data-test='release-inclusion-held']")).toHaveCount(0);

  // The held-back member — amber HELD FROM RELEASE, naming its app.
  const held = page.locator("#card-e2e-release-inclusion-held-demo");
  await expect(held).toBeVisible();
  const heldBar = held.locator("[data-test='release-inclusion-held']");
  await expect(heldBar).toBeVisible();
  await expect(heldBar).toContainText("HELD FROM RELEASE");
  await expect(heldBar).toContainText("mcritchie-studio");
  await expect(held.locator("[data-test='release-inclusion-in']")).toHaveCount(0);
});
