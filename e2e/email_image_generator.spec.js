const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

// [e2e] An admin opens the Turf Monster generator page, sees the character
// model and the examples, fills the email and headline, watches the prompt
// fill live, and copies it. Read-only: Turf Monster is seeded by e2e/seed.rb
// (Characters::SeedTurfMonster); no generator is called. Not @qa-readonly: it
// signs in as the seeded test admin.

test.use({ permissions: ["clipboard-read", "clipboard-write"] });

test("admin opens the turf generator page, fills the headline and copies the prompt", async ({ page }) => {
  await loginWithMagicLink(page, "alex@test.com");

  await page.goto("/email_images/generator/turf-monster");
  await expect(page.getByRole("heading", { name: "Turf Monster email images", level: 1 })).toBeVisible();

  const model = page.locator("[data-test='character-model']");
  await expect(model.locator("[data-test='character-link']")).toHaveText("Turf Monster");
  await expect(model.locator("[data-test='model-image'] img")).toHaveJSProperty("complete", true);
  await expect(page.locator("[data-test='example']").first()).toBeVisible();

  const prompt = page.locator("[data-test='prompt']");
  await expect(prompt).toHaveValue(/Email: <new email key>/);

  await page.locator("[data-test='input-email']").fill("welcome");
  await page.locator("[data-test='input-headline']").fill("Your picks are in");
  const expected = [
    "Run the email-image SOP.",
    "Brand: turf-monster · Email: welcome",
    'Headline: "Your picks are in"',
    "Look: Turf Monster in his canonical look, on-brand pose.",
  ].join("\n");
  await expect(prompt).toHaveValue(expected);

  await page.locator("[data-test='copy-prompt']").click();
  await expect(page.locator("[data-test='copy-prompt']")).toHaveText("Copied");
  expect(await page.evaluate(() => navigator.clipboard.readText())).toBe(expected);
});
