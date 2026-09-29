// [e2e] Per-video looks: the operator makes a look for a labelled test artist
// and builds its character sheet. The server's generator is the e2e fake
// (config/initializers/e2e_image_generation.rb), so nothing is spent. Seeded by
// e2e/seed.rb from db/seeds/data/night_call_looks.rb; artists are synthetic.
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

test("operator makes a look and builds its sheet from the video stills", async ({ page }) => {
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/music_videos/steve-aoki-night-call-looks");

  const candidate = page.locator("[data-test='look-candidate'][data-ordinal='2']");
  await expect(candidate).toContainText("Test Artist B");
  await candidate.getByRole("button", { name: "Make look" }).click();

  const look = page.locator("[data-test='look-card'][data-ordinal='2']");
  await expect(look).toBeVisible();
  // Clearest first: the clear 0:42 still leads the partial 3:06 one it was posted after.
  const refs = look.locator("[data-test='look-reference']");
  await expect(refs).toHaveCount(2);
  await expect(refs.nth(0)).toHaveAttribute("data-visibility", "clear");
  await expect(refs.nth(0)).toHaveAttribute("data-key", /person_02_0042\.jpg$/);
  await expect(refs.nth(1)).toHaveAttribute("data-visibility", "partial");
  await expect(look.locator("[data-test='look-sheet-empty']")).toBeVisible();
  await expect(look.locator("[data-test='look-cost-hint']")).toContainText("Costs money");

  await look.getByRole("button", { name: "Build character sheet" }).click();
  const built = page.locator("[data-test='look-card'][data-ordinal='2']");
  await expect(built.locator("[data-test='look-sheet-image']")).toBeVisible();
  await expect(built.getByRole("button", { name: "Rebuild character sheet" })).toBeVisible();
});
