// [e2e] The search rows on a cast card. Both typeaheads (who is this, and
// "Replace with") draw a headshot or a placeholder, the name, the primary
// vocation and the team; "Replace with" draws them as three columns with the
// primary look. It finds a person who has no look yet, lists them with
// "0 looks", and picking them saves them pending and offers their first look,
// or the by-hand form with the way back. Wholly synthetic data, seeded by e2e/seed.rb
// from db/seeds/data/search_rows_video.rb: only the operator says who is on
// screen and who replaces them.
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

const VIDEO = "/music_videos/test-cinematic-search-rows-demo";
const card = (page) => page.locator("[data-test='performer-card'][data-ordinal='1']");
const recast = (page) => card(page).locator("[data-test='performer-recast']");
const row = (scope, name) => scope.locator("[role='option']").filter({ hasText: name });
// The Replace with list only: the card body also holds the naming search's (hidden) rows.
const swapList = (page) => recast(page).locator("[data-test='recast-results']");
// The swap search, not the look dropdown's trigger (also a combobox).
const search = (page) => recast(page).locator("[data-test='recast-typeahead'] input[role='combobox']");

test("operator finds a look-less athlete in Replace with and is offered a first look", async ({ page }) => {
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto(VIDEO);
  // No toggle first: the search is on the card.
  await expect(recast(page)).toHaveAttribute("data-state", "none");
  await expect(search(page)).toBeVisible();
  await expect(search(page)).toHaveAttribute("placeholder", "Search people by name");

  // Everyone named "test" is listed; a person with looks comes first.
  await search(page).fill("test");
  const options = recast(page).locator("[data-test='recast-option']");
  await expect(options.first()).toContainText("Test Athlete Alpha");
  await expect(options.first().locator("[data-test='search-row-badge']")).toHaveText("2 looks");
  // No headshot on file: the neutral placeholder, never a broken image.
  await expect(options.first().locator("[data-test='search-row-placeholder']")).toBeVisible();
  await expect(options.first().locator("img")).toHaveCount(0);

  // The look-less athlete: headshot, vocation, team, and "0 looks".
  await search(page).fill("rookie");
  const rookie = row(swapList(page), "Test Rookie Bravo");
  await expect(rookie).toHaveCount(1);
  await expect(rookie.locator("[data-test='search-row-headshot']")).toBeVisible();
  await expect(rookie.locator("[data-test='search-row-headshot']")).toHaveJSProperty("complete", true);
  await expect(rookie.locator("[data-test='search-row-placeholder']")).toBeHidden();
  await expect(rookie.locator("[data-test='search-row-vocation']")).toHaveText("athlete");
  await expect(rookie.locator("[data-test='search-row-team']")).toHaveText("Test City Testers");
  await expect(rookie.locator("[data-test='search-row-badge']")).toHaveText("0 looks");
  await expect(rookie.locator("[data-test='search-row-no-look']")).toHaveText("No look yet");

  // Picking him saves him alone, pending: his avatar, name and team, no dropdown, the first-look form,
  // and the by-hand link with the way back.
  await rookie.click();
  await expect(recast(page)).toHaveAttribute("data-state", "pending");
  const chosen = recast(page).locator("[data-test='swap-athlete']");
  await expect(chosen.locator("[data-test='swap-athlete-name']")).toHaveText("Test Rookie Bravo");
  await expect(chosen.locator("[data-test='swap-athlete-team']")).toHaveText("Test City Testers");
  await expect(chosen.locator("[data-test='search-row-headshot']")).toBeVisible();
  // The search stays, emptied, for another pick; Keep Original shows at the bottom of the card even with no look.
  await expect(search(page)).toHaveValue("");
  await expect(recast(page).locator("[data-test='keep-original']")).toBeVisible();
  await expect(recast(page).locator("[data-test='recast-no-look']")).toContainText("Test Rookie Bravo has no look yet");
  await expect(recast(page).locator("[data-test='look-trigger']")).toBeHidden();
  await expect(recast(page).locator("[data-test='look-generate-form']")).toContainText("First look for Test Rookie Bravo");
  const create = recast(page).locator("[data-test='recast-new-look']");
  await expect(create).toHaveText("Or add a look by hand on Test Rookie Bravo’s page");
  await expect(create).toHaveAttribute(
    "href", /\/people\/test-rookie-bravo\?return_to=%2Fmusic_videos%2Ftest-cinematic-search-rows-demo%23person-1#new-model$/);

  // The link opens his look form; saving a look lands back on the card, where he now has one to cast.
  await create.click();
  await expect(page.locator("details#new-model [data-test='new-model-return']")).toBeVisible();
  await page.locator("details#new-model input[name='appearance[descriptor]']").fill("Training Grey");
  await page.locator("details#new-model").getByRole("button", { name: "Save model" }).click();
  await expect(page).toHaveURL(/\/music_videos\/test-cinematic-search-rows-demo(#person-1)?$/);
  await expect(card(page)).toHaveAttribute("data-resolved", "false");
  await expect(recast(page)).toHaveAttribute("data-state", "pending");
  await expect(recast(page).locator("[data-test='recast-pending']")).toContainText("No look saved");
  await expect(recast(page).locator("[data-test='look-trigger']")).toHaveText("Choose a look");
  await recast(page).locator("[data-test='look-trigger']").click();
  // The look and its iced twin are both listed; pick the look itself.
  await expect(recast(page).locator("[data-test='look-option-name']")).toHaveText(["Training Grey", "Training Grey · iced"]);
  await recast(page).locator("[data-test='look-option']").first().click();
  await expect(recast(page)).toHaveAttribute("data-state", "recast");
  await expect(recast(page).locator("[data-test='recast-pending']")).toBeHidden();
  await expect(recast(page).locator("[data-test='look-preview-label']")).toHaveText("Test Rookie Bravo > Training Grey");
  // The search beside the chosen athlete still finds him, with his look now; Escape leaves him chosen.
  await search(page).fill("rookie");
  await expect(row(swapList(page), "Test Rookie Bravo").locator("[data-test='search-row-badge']")).toHaveText("2 looks");
  await search(page).press("Escape");
  await expect(recast(page).locator("[data-test='recast-results']")).toBeHidden();
  await expect(recast(page).locator("[data-test='swap-athlete-name']")).toHaveText("Test Rookie Bravo");
});

test("the artist search draws the same row, and a headshot that fails falls back to the placeholder", async ({ page }) => {
  await loginWithMagicLink(page, "alex@test.com");
  // The athlete's headshot never arrives.
  await page.route("**/icon.png", (route) => route.abort());
  await page.goto(VIDEO);

  // The naming search is always open: nothing to press first.
  const who = card(page).locator("[data-test='performer-typeahead']");
  await who.getByRole("combobox").fill("test");
  // A person not yet an artist, with a failed headshot; the athlete belongs to the swap search, not here.
  const person = row(who, "Test Actor Delta");
  await expect(person.locator("[data-test='search-row-vocation']")).toHaveText("actor");
  await expect(person.locator("[data-test='search-row-badge']")).toHaveText("people");
  await expect(person.locator("[data-test='search-row-placeholder']")).toBeVisible();
  await expect(person.locator("img")).toHaveCount(0);
  await expect(row(who, "Test Rookie Bravo")).toHaveCount(0);

  // An artist with no Person: the placeholder and "musician".
  const artist = row(who, "Test Artist A").first();
  await expect(artist.locator("[data-test='search-row-placeholder']")).toBeVisible();
  await expect(artist.locator("[data-test='search-row-vocation']")).toHaveText("musician");
  await expect(artist.locator("[data-test='search-row-team']")).toBeHidden();

  // A pick made while the debounce of the last keystroke is still pending stands.
  // (The test above may have left this card swapped: the search is there either way.)
  await who.getByRole("combobox").press("Escape");
  await expect(who.locator("[data-test='typeahead-results']")).toBeHidden();
  const combo = search(page);
  await combo.fill("test athlete");
  const alpha = row(swapList(page), "Test Athlete Alpha");
  await expect(alpha).toHaveCount(1);
  await combo.pressSequentially(" a", { delay: 20 });
  await alpha.click();
  await page.waitForTimeout(600);
  await expect(recast(page).locator("[data-test='look-option']")).toHaveCount(2);
  await expect(recast(page).locator("[data-test='recast-results']")).toBeHidden();
});

test("an older search answer that arrives late does not reopen or repaint the list", async ({ page }) => {
  await loginWithMagicLink(page, "alex@test.com");
  // Hold the answer to the first query until the test lets it go.
  let release;
  const held = new Promise((resolve) => { release = resolve; });
  await page.route("**/artists/search.json?q=test", async (route) => {
    await held;
    await route.continue();
  });
  await page.goto(VIDEO);

  // The naming search is always open: nothing to press first.
  const who = card(page).locator("[data-test='performer-typeahead']");
  const combo = who.getByRole("combobox");
  const list = who.locator("[data-test='typeahead-results']");
  const slow = page.waitForRequest((request) => request.url().endsWith("/artists/search.json?q=test"));
  await combo.fill("test");
  await slow;

  // A newer query answers first, and the operator closes the list.
  await combo.fill("actor delta");
  await expect(row(who, "Test Actor Delta")).toHaveCount(1);
  await combo.press("Escape");
  await expect(list).toBeHidden();

  // The old answer lands: the list stays shut and still holds the newer rows.
  const late = page.waitForResponse((response) => response.url().endsWith("/artists/search.json?q=test"));
  release();
  await late;
  await page.waitForTimeout(300);
  await expect(list).toBeHidden();
  expect(await who.locator("[data-test='typeahead-option'] [data-test='search-row-name']").allTextContents())
    .toEqual(["Test Actor Delta"]);
});
