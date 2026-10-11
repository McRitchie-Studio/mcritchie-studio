// [e2e] The player sheet's non-face inputs on the look page: the operator sees the
// body archetype his position defaults to, points the look at another, uses two
// uniform photos and drops one, then opens the archetype page, where every row
// offers a paid Generate it does NOT press. Nothing here spends: no search, no
// generation. Seeded by e2e/seed.rb (Quill Uniformfixture).
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

const LOOK = "/people/quill-uniformfixture/models/look-uniformfixture";

test("operator attaches an archetype and uniform photos to a look", async ({ page }) => {
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto(LOOK);

  const current = page.locator("[data-test='archetype-current']");
  await expect(current).toHaveAttribute("data-slug", "nfl-qb-skill");
  await expect(current).toContainText("default for QB");

  const form = page.locator("[data-test='archetype-form']");
  await form.locator("select").selectOption("nfl-lineman");
  await form.getByRole("button", { name: "Use" }).click();
  await expect(current).toHaveAttribute("data-slug", "nfl-lineman");
  await expect(current).toContainText("chosen for this look");

  const uniform = page.locator("[data-test='uniform-photos']");
  await expect(uniform.locator("[data-test='uniform-none']")).toBeVisible();
  for (let i = 0; i < 2; i++) {
    await uniform.locator("[data-test='uniform-candidates'] [data-test='uniform-use'] button").first().click();
    await expect(uniform.locator("[data-test='uniform-chosen'] [data-test='uniform-photo']")).toHaveCount(i + 1);
  }
  await expect(uniform).toContainText("Uniform photos (2 of 3)");
  await uniform.locator("[data-test='uniform-chosen'] [data-test='uniform-drop'] button").first().click();
  await expect(uniform.locator("[data-test='uniform-chosen'] [data-test='uniform-photo']")).toHaveCount(1);

  await page.locator("[data-test='archetype-picker']").getByRole("link", { name: "All archetypes" }).click();
  await expect(page).toHaveURL(/\/body-archetypes$/);
  await expect(page.locator("[data-test='archetype']")).toHaveCount(3);
  await expect(page.locator("[data-test='archetype-no-image']")).toHaveCount(3);
  await expect(page.locator("[data-test='archetype-generate']")).toHaveCount(3);
});
