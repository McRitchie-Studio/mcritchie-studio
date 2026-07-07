const { test, expect } = require("@playwright/test");

// E2E (happy path): the board crew circle for a SHINY mascot paints the shiny
// sprite — the seeded shiny-mascot-demo card wears pikachu's gold data URI
// (e2e/seed.rb), never the transparent normal one.
const SHINY_SPRITE =
  "data:image/gif;base64,R0lGODlhAQABAPAAAP/XAAAAACH5BAAAAAAALAAAAAABAAEAAAICRAEAOw==";

test("shiny mascot card wears the shiny sprite on the board", async ({ page }) => {
  await page.goto("/tasks");

  const card = page.locator("#card-shiny-mascot-demo");
  await expect(card).toBeVisible();

  const shinyAvatar = card.locator(`img[src="${SHINY_SPRITE}"]`).first();
  await expect(shinyAvatar).toBeVisible();
  await expect(card.locator("[data-test='avatar-shiny-badge']").first()).toHaveText("✨");
});
