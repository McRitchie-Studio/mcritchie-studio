// [e2e] The cast panel: naming is optional. Cast confirmed is ready with nobody
// named and nothing pressed; the operator still names some people through the
// always-open "Who is this on screen?" search at the bottom of each card (an
// alias match, then a brand-new artist) to build the rolodex, marks one as an
// extra, and confirms. Each saves at once, without a reload. Seeded by e2e/seed.rb from
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
  await expect(page.locator("[data-test='performer-recast'][data-state='none']")).toHaveCount(7);
  await expect(page.locator("[data-test='cast-named-count']")).toContainText("Nobody named. Naming is optional");
  const confirm = page.getByRole("button", { name: "Cast confirmed" });
  await expect(confirm).toBeEnabled();

  // The naming search is always open, nothing to press first, under its small label.
  await expect(who(page, 1)).toBeVisible();
  await expect(who(page, 1)).toHaveAttribute("placeholder", "Search artists and people");
  await expect(card(page, 1).locator("[data-test='performer-resolution'] label")).toHaveText("Who is this on screen? (optional)");
  await expect(card(page, 1).locator("[data-test='name-artist-open']")).toHaveCount(0);

  // The description and sightings fold behind the title. Pressing Person 2 opens one row of the clearly
  // visible chips with "+N more" for the rest; pressing that shows every chip; the title folds them again.
  const title = card(page, 2).locator("[data-test='performer-title']");
  const details = card(page, 2).locator("[data-test='card-details']");
  const partial = card(page, 2).locator("[data-test='sightings-partial']");
  const more = card(page, 2).locator("[data-test='sightings-more']");
  const visibleTops = (loc) => loc.evaluateAll((els) => els.filter((e) => e.offsetParent).map((e) => e.getBoundingClientRect().top));
  await expect(title.locator("[data-test='performer-title-name']")).toHaveText("Person 2");
  await expect(title).toHaveAttribute("aria-expanded", "false");
  await expect(details).toBeHidden();
  await title.click();
  await expect(title).toHaveAttribute("aria-expanded", "true");
  await expect(more).toBeVisible();
  await expect(partial).toBeHidden();
  const row = await visibleTops(card(page, 2).locator("[data-test='sightings-clear'] [data-test='sighting']"));
  expect(row.length).toBeGreaterThan(0);
  expect(row.length).toBeLessThan(10);
  const moreTop = (await more.boundingBox()).y;
  for (const t of row) expect(Math.abs(t - moreTop)).toBeLessThan(4);
  await expect(more).toHaveText(`+${10 - row.length + 4} more`);
  await expect(card(page, 2).locator("a[data-test='sighting']").first()).toHaveAttribute("target", "_blank");
  await more.click();
  await expect(partial).toBeVisible();
  await expect(more).toBeHidden();
  expect((await visibleTops(card(page, 2).locator("[data-test='sighting']"))).length).toBe(14);
  await title.click();
  await expect(details).toBeHidden();
  await expect(title).toHaveAttribute("aria-expanded", "false");
  // Every save below happens in place: this marker would vanish on a reload.
  await page.evaluate(() => { window.__castNoReload = true; });

  // Person 1: an alias finds Test Artist A; picking it saves at once.
  await who(page, 1).fill("test alias a");
  const option = card(page, 1).locator("[data-test='typeahead-option']").first();
  await expect(option).toContainText("Test Artist A");
  await expect(option).toContainText("aka Test Alias A");
  await option.click();
  await expect(card(page, 1).locator("[data-test='naming-saved']")).toBeVisible();
  await expect(card(page, 1).locator("[data-test='performer-artist']")).toContainText("Test Artist A");
  await expect(card(page, 1).locator("[data-test='performer-badge']")).toHaveText("Named");
  // The title follows the name without a reload, Person 1 beside it.
  await expect(card(page, 1).locator("[data-test='performer-title-name']")).toHaveText("Test Artist A");
  await expect(card(page, 1).locator("[data-test='performer-title-ordinal']")).toBeVisible();
  await expect(card(page, 1).locator("[data-test='performer-title-ordinal']")).toHaveText("Person 1");
  await expect(who(page, 1)).toHaveValue("");
  await expect(who(page, 1)).toBeVisible();

  // Person 2: nobody matches, so the operator creates the artist inline.
  await who(page, 2).fill("Test Artist E");
  await card(page, 2).locator("[data-test='typeahead-create']").click();
  await expect(card(page, 2).getByLabel("New artist name")).toHaveValue("Test Artist E");
  await card(page, 2).getByRole("button", { name: "Create and link" }).click();
  await expect(card(page, 2).locator("[data-test='naming-saved']")).toBeVisible();
  await expect(card(page, 2).locator("[data-test='performer-artist']")).toContainText("Test Artist E");

  // Person 4: named, then Clear takes it back to the search alone.
  await who(page, 4).fill("test alias a");
  await card(page, 4).locator("[data-test='typeahead-option']").first().click();
  await expect(card(page, 4).locator("[data-test='performer-badge']")).toHaveText("Named");
  await card(page, 4).locator("[data-test='performer-artist-clear']").click();
  await expect(card(page, 4).locator("[data-test='naming-saved']")).toBeVisible();
  await expect(card(page, 4).locator("[data-test='performer-artist']")).toBeHidden();
  await expect(card(page, 4).locator("[data-test='performer-badge']")).toHaveText("Not named");
  await expect(card(page, 4).locator("[data-test='performer-title-name']")).toHaveText("Person 4");
  await expect(card(page, 4).locator("[data-test='performer-title-ordinal']")).toBeHidden();

  // Person 3: the quiet extra link records an extra, a small chip that can be removed and set again.
  await card(page, 3).getByRole("button", { name: "Mark as extra" }).click();
  await expect(card(page, 3).locator("[data-test='performer-extra']")).toContainText("An extra, not a named artist");
  await expect(card(page, 3).locator("[data-test='performer-badge']")).toHaveText("Extra");
  await card(page, 3).locator("[data-test='performer-extra-remove']").click();
  await expect(card(page, 3).locator("[data-test='performer-badge']")).toHaveText("Not named");
  await expect(card(page, 3).locator("[data-test='naming-saved']")).toBeVisible();
  await card(page, 3).getByRole("button", { name: "Mark as extra" }).click();
  await expect(card(page, 3).locator("[data-test='performer-badge']")).toHaveText("Extra");
  await expect(card(page, 3).locator("[data-test='performer-title-name']")).toHaveText("Person 3");
  await expect(card(page, 2).locator("[data-test='performer-title-name']")).toHaveText("Test Artist E");
  await expect(page.locator("[data-test='cast-named-count']")).toContainText("2 of 7 named (1 marked extras)");
  expect(await page.evaluate(() => window.__castNoReload)).toBe(true);

  // Persons 4-7 stay unnamed, and the cast confirms.
  await expect(confirm).toBeEnabled();
  await confirm.click();
  await expect(page.locator("[data-test='cast-confirmed']")).toBeVisible();
  await expect(page.locator("[data-test='video-stage']")).toHaveText("Cast confirmed");
  // Naming stays optional after the confirm: the search is still there.
  await expect(who(page, 7)).toBeVisible();
});
