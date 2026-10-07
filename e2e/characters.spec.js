const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

// [e2e] An admin opens the cast at /characters, opens Turf Monster, and sees
// his profile and his default Classic look with its kit art. Read-only: the
// character is seeded by e2e/seed.rb through Characters::SeedTurfMonster. Not
// @qa-readonly: it signs in as the seeded test admin and reads a seeded row.

test("admin opens the cast, opens Turf Monster and sees his look", async ({ page }) => {
  await loginWithMagicLink(page, "alex@test.com");

  await page.goto("/characters");
  await expect(page.getByRole("heading", { name: "Characters" })).toBeVisible();
  const card = page.locator("[data-test='cast-card'][data-character='turf-monster']");
  await expect(card.locator("[data-test='cast-kind']")).toHaveText("mascot");
  await expect(card.locator("[data-test='cast-looks']")).toHaveText("1 look");
  await card.click();

  await expect(page).toHaveURL(/\/characters\/turf-monster$/);
  await expect(page.getByRole("heading", { name: "Turf Monster", level: 1 })).toBeVisible();
  await expect(page.locator("[data-test='profile-bio']")).toContainText("green, furry gator");

  const look = page.locator("[data-test='character-look']");
  await expect(look).toHaveCount(1);
  await expect(look.locator("[data-test='look-name']")).toHaveText("Classic");
  await expect(look.locator("[data-test='look-default']")).toHaveText("default");
  await expect(look.locator("[data-test='look-art'] img")).toHaveCount(2);
  await expect(look.locator("[data-test='look-art'] img").first()).toHaveJSProperty("naturalWidth", 768);
});
