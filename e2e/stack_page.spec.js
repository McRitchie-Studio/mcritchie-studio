// [e2e] /stack — every client's stack, as an admin sees it.
//
// e2e/seed.rb loads db/seeds/59_credentials.rb and 60_stack_clients.rb. What only
// a browser proves: the logos actually load (a broken asset path still renders an
// <img>), and the hosted-vs-own distinction survives to the page.
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

test("admin reads each client's tier and software, with hosted logos badged", async ({ page }) => {
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/stack");

  await expect(page.getByRole("heading", { name: "Every client's stack" })).toBeVisible();

  const turf = page.locator("[data-test='stack-client'][data-client='turf-monster']");
  await expect(turf.locator("[data-test='stack-tier']")).toContainText("Agentic");

  // Google is ours on every client: it wears the Studio chest, and the image loaded.
  const google = turf.locator("[data-test='stack-software-icon'][data-software='google']");
  await expect(google).toHaveAttribute("data-hosting", "ms");
  expect(await google.locator("img").evaluate((img) => img.naturalWidth)).toBeGreaterThan(0);

  // X is Turf's own account: plain logo.
  await expect(turf.locator("[data-test='stack-software-icon'][data-software='x']")).toHaveAttribute("data-hosting", "own");

  await expect(turf.locator("[data-test='stack-resend']")).toContainText("McRitchie Studio account");
});
