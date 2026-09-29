// [e2e] The cast panel: the operator labels people through the typeahead (an
// alias match, then a brand-new artist), marks the rest as extras, and confirms.
// Seeded by e2e/seed.rb from db/seeds/data/night_call_cast.rb.
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

const card = (page, n) => page.locator(`[data-test='performer-card'][data-ordinal='${n}']`);

test("operator labels people via the typeahead and confirms the cast", async ({ page }) => {
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/music_videos/steve-aoki-night-call");

  await expect(page.locator("[data-test='performer-card']")).toHaveCount(7);
  await expect(page.locator("[data-test='unresolved-credit']")).toContainText("Steve Aoki");
  const confirm = page.getByRole("button", { name: "Cast confirmed" });
  await expect(confirm).toBeDisabled();

  // Person 1: an alias finds Lil Yachty; picking it saves and reloads the card.
  await card(page, 1).getByRole("combobox").fill("lil boat");
  const option = card(page, 1).locator("[data-test='typeahead-option']").first();
  await expect(option).toContainText("Lil Yachty");
  await expect(option).toContainText("aka Lil Boat");
  await option.click();
  await expect(card(page, 1).locator("[data-test='performer-artist']")).toContainText("Lil Yachty");

  // Person 2: nobody matches, so the operator creates the artist inline.
  await card(page, 2).getByRole("combobox").fill("Steve Aoki");
  await card(page, 2).locator("[data-test='typeahead-create']").click();
  await expect(card(page, 2).getByLabel("New artist name")).toHaveValue("Steve Aoki");
  await card(page, 2).getByRole("button", { name: "Create and link" }).click();
  await expect(card(page, 2).locator("[data-test='performer-artist']")).toContainText("Steve Aoki");

  // The rest are extras; the button unlocks only when the last one is answered.
  for (const n of [3, 4, 5, 6]) {
    await card(page, n).getByRole("button", { name: "Extra, not a named artist" }).click();
    await expect(card(page, n)).toHaveAttribute("data-resolved", "true");
  }
  await expect(confirm).toBeDisabled();
  await card(page, 7).getByRole("button", { name: "Extra, not a named artist" }).click();
  await expect(card(page, 7)).toHaveAttribute("data-resolved", "true");

  await expect(confirm).toBeEnabled();
  await confirm.click();
  await expect(page.locator("[data-test='cast-confirmed']")).toBeVisible();
  await expect(page.locator("[data-test='video-stage']")).toHaveText("Cast confirmed");
});
