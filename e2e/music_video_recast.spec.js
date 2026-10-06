// [e2e] Replace with on a cast card: the people search is on every card, no
// toggle first. The operator searches an athlete in the wide three-column list,
// and picking him IS the swap: it saves at once in his default look; switching
// the look saves again; the swap count above the cards follows each save
// without a reload, and Build Clips snapshots the swap into an alt video whose
// prompts name it. A dropped save says so and Retry sends it again. The one button
// pinned at the bottom of the card reads Keep Original while swapping (turns the
// swap off and hides it, remembering him) and Swap back to <name> while kept
// (restores him), in the same place; picking someone else swaps to them.
// Replace with sits at the top of the card, naming at the bottom. Saves land in the
// order made, so a change made while one is in flight never leaves the server
// behind the card. A cinematic video, so no prompt says "music video". Wholly
// synthetic data, seeded by e2e/seed.rb from db/seeds/data/recast_video.rb:
// only the operator says who is on screen and who replaces them.
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

const VIDEO = "/music_videos/test-cinematic-recast-demo";
const card = (page, n) => page.locator(`[data-test='performer-card'][data-ordinal='${n}']`);
const recast = (page, n) => card(page, n).locator("[data-test='performer-recast']");
// The swap search, not the look dropdown's trigger (also a combobox).
const search = (page, n) => recast(page, n).locator("[data-test='recast-typeahead'] input[role='combobox']");
const keepButton = (page, n) => recast(page, n).locator("[data-test='keep-original']");
const swapBack = (page, n) => recast(page, n).locator("[data-test='swap-back']");

// Back to nobody picked, whatever a previous test or retry left on the card.
async function clearCard(page, n) {
  if ((await recast(page, n).getAttribute("data-state")) === "kept") await swapBack(page, n).click();
  if ((await recast(page, n).getAttribute("data-state")) !== "none") {
    await recast(page, n).locator("[data-test='swap-clear']").click();
    await expect(recast(page, n).locator("[data-test='swap-saved']")).toBeVisible();
  }
  await expect(recast(page, n)).toHaveAttribute("data-state", "none");
}

async function pick(page, n, query, name) {
  await search(page, n).fill(query);
  await recast(page, n).locator("[data-test='recast-option']").filter({ hasText: name }).first().click();
}

test("operator picks an athlete from Replace with, keeps the original, swaps back, and picks another", async ({ page }) => {
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto(VIDEO);
  await clearCard(page, 1);

  await expect(page.locator("[data-test='video-kind']")).toHaveText("Cinematic video · Cast");
  await expect(page.locator("[data-test='cast-confirmed']")).toBeVisible();

  // Seeded under the old "keep as is" with nobody: only the search, no toggle, no hint, no Keep Original.
  const swapCount = page.locator("[data-test='cast-swap-count']");
  await expect(search(page, 1)).toBeVisible();
  await expect(keepButton(page, 1)).toBeHidden();
  await expect(recast(page, 1).locator("input[type='checkbox']")).toHaveCount(0);
  // Replace with is at the top, above the sightings (folded behind the title, so open them); the bottom
  // block (swap toggle, then naming) is under them.
  const top = async (sel) => (await card(page, 1).locator(sel).first().boundingBox()).y;
  await card(page, 1).locator("[data-test='performer-title']").click();
  await expect(card(page, 1).locator("[data-test='card-details']")).toBeVisible();
  expect(await top("[data-test='replace-with']")).toBeLessThan(await top("[data-test='card-details']"));
  expect(await top("[data-test='card-details']")).toBeLessThan(await top("[data-test='card-bottom']"));
  expect(await top("[data-test='card-bottom']")).toBeLessThan(await top("[data-test='performer-resolution']"));
  await card(page, 1).locator("[data-test='performer-title']").click();
  await expect(card(page, 1).locator("[data-test='card-details']")).toBeHidden();
  await expect(recast(page, 1).locator("[data-test='swap-athlete']")).toBeHidden();
  await expect(recast(page, 1)).not.toContainText("Check to replace");
  await expect(recast(page, 1).locator("[role='switch']")).toHaveCount(0);
  await expect(swapCount).toHaveText(/^0 of \d+$/);

  // The list is wider than the field, three columns per row, and stays on screen.
  const combo = search(page, 1);
  await combo.fill("test athlete");
  const option = recast(page, 1).locator("[data-test='recast-option']").first();
  await expect(option).toContainText("Test Athlete Alpha");
  await expect(option.locator("[data-test='search-row-badge']")).toHaveText("2 looks");
  await expect(option.locator("[data-test='search-row-look-name']")).toHaveText("Home Blue");
  const list = await recast(page, 1).locator("[data-test='recast-results']").boundingBox();
  const field = await combo.boundingBox();
  expect(list.width).toBeGreaterThan(field.width);
  expect(list.x + list.width).toBeLessThanOrEqual(page.viewportSize().width);
  const name = await option.locator("[data-test='search-row-name']").boundingBox();
  const look = await option.locator("[data-test='search-row-look-cell']").boundingBox();
  expect(look.x).toBeGreaterThan(name.x);
  expect(Math.abs(look.y - name.y)).toBeLessThan(name.height * 2);

  // The pick is the swap: saved at once in his default look, Keep Original under his sheet, the count follows.
  await option.click();
  await expect(recast(page, 1)).toHaveAttribute("data-state", "recast");
  await expect(recast(page, 1).locator("[data-test='swap-saved']")).toBeVisible();
  await expect(recast(page, 1).locator("[data-test='swap-athlete-name']")).toHaveText("Test Athlete Alpha");
  await expect(recast(page, 1).locator("[data-test='swap-athlete-utility']")).toContainText("athlete");
  await expect(keepButton(page, 1)).toBeVisible();
  const sheet = await recast(page, 1).locator("[data-test='look-preview']").boundingBox();
  const button = await keepButton(page, 1).boundingBox();
  expect(button.y).toBeGreaterThanOrEqual(sheet.y + sheet.height - 1);
  expect(Math.abs(button.width - sheet.width)).toBeLessThan(2);
  await expect(combo).toHaveValue("");
  await expect(recast(page, 1).locator("[data-test='look-cast']")).toHaveCount(0);
  await expect(swapCount).toHaveText(/^1 of \d+$/);

  // Switching the look saves it too.
  const trigger = recast(page, 1).locator("[data-test='look-trigger']");
  await trigger.click();
  await expect(recast(page, 1).locator("[data-test='look-option-name']")).toHaveText(["Home Blue", "Away White"]);
  await recast(page, 1).locator("[data-test='look-option']").filter({ hasText: "Away White" }).click();
  await expect(recast(page, 1).locator("[data-test='swap-saved']")).toBeVisible();
  await expect(trigger).toHaveText("Away White");

  // A dropped save says so; Retry sends it again.
  let drop = true;
  await page.route("**/performers/1/recast", (route) => (drop ? route.abort() : route.continue()));
  await trigger.click();
  await recast(page, 1).locator("[data-test='look-option']").filter({ hasText: "Home Blue" }).click();
  await expect(recast(page, 1).locator("[data-test='swap-failed']")).toBeVisible();
  await expect(recast(page, 1).locator("[data-test='swap-error']")).toHaveText("The connection dropped.");
  await expect(recast(page, 1)).toHaveAttribute("data-state", "recast");
  drop = false;
  await recast(page, 1).locator("[data-test='swap-retry']").click();
  await expect(recast(page, 1).locator("[data-test='swap-saved']")).toBeVisible();
  await expect(trigger).toHaveText("Home Blue");
  await page.unroute("**/performers/1/recast");

  // A reload reads the save back: the athlete block, the look, Keep Original under the sheet.
  await page.reload();
  await expect(recast(page, 1)).toHaveAttribute("data-state", "recast");
  await expect(recast(page, 1).locator("[data-test='swap-athlete-name']")).toHaveText("Test Athlete Alpha");
  await expect(trigger).toHaveText("Home Blue");
  await expect(keepButton(page, 1)).toBeVisible();

  // The by-hand link lands on the athlete's look form, which knows the way back.
  await expect(recast(page, 1).locator("[data-test='recast-new-look']")).toHaveAttribute(
    "href", /\/people\/test-athlete-alpha\?return_to=%2Fmusic_videos%2Ftest-cinematic-recast-demo%23person-1#new-model$/);
  await recast(page, 1).locator("[data-test='recast-new-look']").click();
  await expect(page).toHaveURL(/\/people\/test-athlete-alpha\?return_to=/);
  await expect(page.locator("details#new-model [data-test='new-model-return']")).toBeVisible();
  await page.goBack();

  // Keep Original, at the bottom above the naming: the swap is off and hidden, he is remembered, and the
  // blank comes back to the prompts. Swap back takes the same place, so it is where the eye already is.
  // Measured against the naming block it sits on, which does not move between the two states.
  const fromBottom = async (button) => {
    const [n, b] = [await card(page, 1).locator("[data-test='performer-resolution']").boundingBox(), await button.boundingBox()];
    return Math.round(n.y - b.y);
  };
  // Both states settle at the same distance: the h-10 button and the space-y-3 gap above the naming.
  const keepAt = 40 + 12;
  await expect.poll(() => fromBottom(keepButton(page, 1))).toBe(keepAt);
  expect(await top("[data-test='keep-original']")).toBeLessThan(await top("[data-test='performer-resolution']"));
  await keepButton(page, 1).click();
  await expect(recast(page, 1)).toHaveAttribute("data-state", "kept");
  await expect(recast(page, 1).locator("[data-test='swap-saved']")).toBeVisible();
  await expect(recast(page, 1).locator("[data-test='swap-athlete']")).toBeHidden();
  await expect(trigger).toBeHidden();
  await expect(recast(page, 1).locator("[data-test='look-preview']")).toBeHidden();
  await expect(keepButton(page, 1)).toBeHidden();
  await expect(swapBack(page, 1)).toHaveText(/Swap back to\s+Test Athlete Alpha/);
  // Read once settled: a read mid-render can land a few pixels short.
  await expect.poll(() => fromBottom(swapBack(page, 1))).toBe(keepAt);
  await expect(search(page, 1)).toBeVisible();
  await expect(swapCount).toHaveText(/^0 of \d+$/);

  // A reload still reads kept; Swap back restores the same athlete and look with no re-pick.
  await page.reload();
  await expect(recast(page, 1)).toHaveAttribute("data-state", "kept");
  await expect(recast(page, 1).locator("[data-test='swap-athlete']")).toBeHidden();
  await swapBack(page, 1).click();
  await expect(recast(page, 1)).toHaveAttribute("data-state", "recast");
  await expect(recast(page, 1).locator("[data-test='swap-saved']")).toBeVisible();
  await expect(recast(page, 1).locator("[data-test='swap-athlete-name']")).toHaveText("Test Athlete Alpha");
  await expect(trigger).toHaveText("Home Blue");
  await expect(swapCount).toHaveText(/^1 of \d+$/);

  // Build Clips snapshots the swap: the new alt video's prompts name the athlete and look.
  await page.locator("[data-test='cast-progress']").getByRole("button", { name: "Build Clips" }).click();
  const clipPrompt = page.locator("[data-test='alt-clip'][data-ordinal='1'] [data-test='clip-prompt']");
  await expect(clipPrompt).toContainText("Replace the man in the red jacket in this video with Test Athlete Alpha, the football player.");
  await expect(clipPrompt).toContainText("(like the Home Blue model provided)");
  await expect(clipPrompt).not.toContainText("music video");
  await expect(page.locator("[data-test='alt-video-swap'][data-ordinal='1']")).toContainText("Test Athlete Alpha > Home Blue");
  await page.goto(VIDEO);

  // Kept again, then a pick from the search ends the keep and swaps to the new person.
  await keepButton(page, 1).click();
  await expect(recast(page, 1).locator("[data-test='swap-saved']")).toBeVisible();
  await pick(page, 1, "rookie", "Test Rookie Bravo");
  await expect(swapBack(page, 1)).toBeHidden();
  await expect(keepButton(page, 1)).toBeVisible();
  await expect(recast(page, 1).locator("[data-test='swap-athlete-name']")).toHaveText("Test Rookie Bravo");
  await expect(recast(page, 1).locator("[data-test='swap-saved']")).toBeVisible();
  await page.reload();
  await expect(recast(page, 1).locator("[data-test='swap-athlete-name']")).toHaveText("Test Rookie Bravo");
  await expect(recast(page, 1)).not.toHaveAttribute("data-state", "kept");

  // Clear forgets the person: the card is back to the search alone.
  await recast(page, 1).locator("[data-test='swap-clear']").click();
  await expect(recast(page, 1)).toHaveAttribute("data-state", "none");
  await expect(recast(page, 1).locator("[data-test='swap-saved']")).toBeVisible();
  await expect(keepButton(page, 1)).toBeHidden();
  await expect(swapBack(page, 1)).toBeHidden();
  await expect(search(page, 1)).toBeFocused();
  await page.reload();
  await expect(recast(page, 1)).toHaveAttribute("data-state", "none");

  // Person 2 named after someone who has looks is offered the swap at once (no reload), never given it:
  // one click picks him.
  await card(page, 2).locator("[data-test='performer-typeahead'] input[role='combobox']").fill("test athlete alpha");
  await card(page, 2).locator("[data-test='typeahead-option']").filter({ hasText: "Test Athlete Alpha" }).first().click();
  await expect(card(page, 2).locator("[data-test='performer-artist-name']")).toHaveText("Test Athlete Alpha");
  await expect(card(page, 2).locator("[data-test='performer-artist-utility']")).toContainText("athlete");
  await expect(card(page, 2).locator("[data-test='performer-artist-clear']")).toBeVisible();
  await expect(recast(page, 2)).toHaveAttribute("data-state", "none");
  const offer = recast(page, 2).locator("[data-test='swap-offer']");
  await expect(offer).toHaveText("Swap with Test Athlete Alpha?");
  await offer.click();
  await expect(recast(page, 2)).toHaveAttribute("data-state", "recast");
  await expect(recast(page, 2).locator("[data-test='swap-saved']")).toBeVisible();
  await expect(recast(page, 2).locator("[data-test='look-trigger']")).toHaveText("Home Blue");
  await expect(offer).toBeHidden();

  // At phone width the wide list opened from the top of a card lands on screen the first time,
  // not only after a resize refits it (it once measured itself before it was painted).
  await page.setViewportSize({ width: 390, height: 844 });
  await page.reload();
  await search(page, 1).fill("test athlete");
  const results = recast(page, 1).locator("[data-test='recast-results']");
  await expect(results.locator("[data-test='recast-option']").first()).toBeVisible();
  await page.waitForTimeout(300);
  const box = await results.boundingBox();
  expect(box.x).toBeGreaterThanOrEqual(0);
  expect(box.x + box.width).toBeLessThanOrEqual(390);
});

// The race piece 10's review named: a change made while the pick's save is in flight, then
// Keep Original before it returns. Saves go one at a time in the order made, so the server
// ends where the card does: Away White remembered, not swapped.
test("changes made while a save is in flight land in order: the server ends where the card does", async ({ page }) => {
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto(VIDEO);
  await clearCard(page, 1);

  let release;
  const held = new Promise((resolve) => { release = resolve; });
  const sent = [];
  await page.route("**/performers/1/recast", async (route) => {
    sent.push(JSON.parse(route.request().postData()));
    if (sent.length === 1) await held;
    await route.continue();
  });

  await pick(page, 1, "test athlete", "Test Athlete Alpha");
  await expect(recast(page, 1).locator("[data-test='swap-saving']")).toBeVisible();
  await recast(page, 1).locator("[data-test='look-trigger']").click();
  await recast(page, 1).locator("[data-test='look-option']").filter({ hasText: "Away White" }).click();
  await keepButton(page, 1).click();
  await expect(recast(page, 1)).toHaveAttribute("data-state", "kept");
  expect(sent.length).toBe(1);

  release();
  await expect(recast(page, 1).locator("[data-test='swap-saved']")).toBeVisible();
  await expect.poll(() => sent.length).toBe(3);
  // The pick, the look change queued behind it, then Keep Original: none dropped, none reordered.
  expect(sent.map((body) => (body.keep ? "keep" : body.person_slug ? "pick" : "other"))).toEqual(["pick", "pick", "keep"]);
  expect(sent[1].appearance_slug).not.toBe(sent[0].appearance_slug);
  await page.unroute("**/performers/1/recast");

  await page.reload();
  await expect(recast(page, 1)).toHaveAttribute("data-state", "kept");
  await swapBack(page, 1).click();
  await expect(recast(page, 1).locator("[data-test='swap-saved']")).toBeVisible();
  await expect(recast(page, 1).locator("[data-test='look-trigger']")).toHaveText("Away White");
  await clearCard(page, 1);
});
