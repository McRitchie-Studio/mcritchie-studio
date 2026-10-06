// [e2e] The cast panel: naming is optional. Cast confirmed is ready with nobody
// named and nothing pressed; the operator still names some people through the
// typeahead (an alias match, then a brand-new artist) to build the rolodex,
// marks one as an extra, and confirms. Seeded by e2e/seed.rb from
// db/seeds/data/night_call_cast.rb. Every label is a synthetic test artist:
// only the operator maps an on-screen person to a real one.
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

const card = (page, n) => page.locator(`[data-test='performer-card'][data-ordinal='${n}']`);
// The card has a second combobox (the swap search): name the artist one.
const who = (page, n) => card(page, n).locator("[data-test='performer-typeahead']").getByRole("combobox");

test("operator confirms the cast without naming everyone, naming two and marking one an extra", async ({ page }) => {
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/music_videos/steve-aoki-night-call");

  await expect(page.locator("[data-test='performer-card']")).toHaveCount(7);
  await expect(page.locator("[data-test='unresolved-credit']")).toContainText("Steve Aoki");
  // Nothing has to be pressed: every card reads Not named and is not swapped, and Cast confirmed is ready.
  await expect(page.locator("[data-test='performer-badge']").filter({ hasText: "Not named" })).toHaveCount(7);
  await expect(page.locator("[data-test='performer-card'][data-resolved='true']")).toHaveCount(7);
  await expect(page.locator("[data-test='performer-recast'][data-state='off']")).toHaveCount(7);
  await expect(page.locator("[data-test='cast-named-count']")).toContainText("Nobody named. Naming is optional");
  const confirm = page.getByRole("button", { name: "Cast confirmed" });
  await expect(confirm).toBeEnabled();

  // Person 1: an alias finds Test Artist A; picking it saves and reloads the card.
  await who(page, 1).fill("test alias a");
  const option = card(page, 1).locator("[data-test='typeahead-option']").first();
  await expect(option).toContainText("Test Artist A");
  await expect(option).toContainText("aka Test Alias A");
  await option.click();
  await expect(card(page, 1).locator("[data-test='performer-artist']")).toContainText("Test Artist A");
  await expect(card(page, 1).locator("[data-test='performer-badge']")).toHaveText("Named");

  // Person 2: nobody matches, so the operator creates the artist inline.
  await who(page, 2).fill("Test Artist E");
  await card(page, 2).locator("[data-test='typeahead-create']").click();
  await expect(card(page, 2).getByLabel("New artist name")).toHaveValue("Test Artist E");
  await card(page, 2).getByRole("button", { name: "Create and link" }).click();
  await expect(card(page, 2).locator("[data-test='performer-artist']")).toContainText("Test Artist E");

  // Person 3: the quiet extra link still records an extra.
  await card(page, 3).getByRole("button", { name: "Mark as extra" }).click();
  await expect(card(page, 3).locator("[data-test='performer-badge']")).toHaveText("Extra");
  await expect(page.locator("[data-test='cast-named-count']")).toContainText("2 of 7 named (1 marked extras)");

  // Persons 4-7 stay unnamed, and the cast confirms.
  await expect(confirm).toBeEnabled();
  await confirm.click();
  await expect(page.locator("[data-test='cast-confirmed']")).toBeVisible();
  await expect(page.locator("[data-test='video-stage']")).toHaveText("Cast confirmed");
  await expect(card(page, 7).locator("[data-test='performer-unlabelled']")).toHaveText("Not named.");
});
