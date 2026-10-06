// [e2e] The look dropdown on a cast card. The operator opens it and sees each
// look of the chosen athlete with its character-sheet thumbnail; picking one
// casts it at once; generating a new look without leaving the card casts the
// new look, shows it building and repaints itself when the sheet is ready. An
// athlete with no look is saved as pending and offered "Generate first look". The server's
// generator is the e2e fake (config/initializers/e2e_image_generation.rb), so
// nothing is spent. Wholly synthetic data, seeded by e2e/seed.rb from
// db/seeds/data/look_picker_video.rb: only the operator says who is on screen
// and who replaces them.
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

const VIDEO = "/music_videos/test-cinematic-look-picker-demo";
const card = (page, n) => page.locator(`[data-test='performer-card'][data-ordinal='${n}']`);
const recast = (page, n) => card(page, n).locator("[data-test='performer-recast']");
const option = (scope, name) => scope.locator("[data-test='look-option']").filter({ hasText: name });

test("operator opens the look dropdown, previews a look, and generates a new one from the card", async ({ page }) => {
  const name = `Road Teal ${Date.now()}`;
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto(VIDEO);

  // The saved card previews the look it is cast in, large, with the way to the look's own page.
  const picker = recast(page, 2);
  await expect(picker).toHaveAttribute("data-state", "recast");
  await expect(picker.locator("[data-test='swap-athlete-name']")).toHaveText("Demo Winger Delta");
  const preview = picker.locator("[data-test='look-preview']");
  await expect(preview.locator("[data-test='look-preview-label']")).toHaveText("Demo Winger Delta > Home Orange");
  await expect(preview.locator("[data-test='look-preview-image']")).toBeVisible();
  await expect(preview.locator("[data-test='look-preview-image']")).toHaveJSProperty("complete", true);
  await expect(preview.locator("[data-test='look-page-link']")).toHaveAttribute("href", /^\/people\/demo-winger-delta\/models\/look-[0-9a-f]+$/);
  await expect(picker.locator("[data-test='look-cast']")).toHaveCount(0);
  await expect(picker.locator("[data-test='look-building-note']")).toContainText("Alternate Blue");

  // The dropdown: a row per look with its sheet thumbnail or a placeholder, the default mark, the build state.
  const trigger = picker.locator("[data-test='look-trigger']");
  await expect(trigger).toHaveText("Home Orange");
  await trigger.click();
  await expect(trigger).toHaveAttribute("aria-expanded", "true");
  const rows = picker.locator("[data-test='look-option']");
  await expect(rows.locator("[data-test='look-option-name']")).toHaveText(["Home Orange", "Away White", "Alternate Blue"]);
  await expect(rows.locator("[data-test='look-option-state']")).toHaveText(["Character sheet ready", "No character sheet yet", "Character sheet building…"]);
  await expect(option(picker, "Home Orange").locator("[data-test='look-thumb-image']")).toBeVisible();
  await expect(option(picker, "Home Orange").locator("[data-test='look-option-default']")).toBeVisible();
  await expect(option(picker, "Home Orange")).toHaveAttribute("aria-selected", "true");
  await expect(option(picker, "Away White").locator("[data-test='look-thumb-placeholder']")).toBeVisible();
  await expect(option(picker, "Away White").locator("img")).toHaveCount(0);
  await expect(option(picker, "Away White").locator("[data-test='look-option-default']")).toBeHidden();
  await expect(picker.locator("[data-test='look-generate-option']")).toHaveText(/Generate a new look/);

  // By keyboard: down one row, Enter. The pick is cast at once: no Cast button to press.
  await page.keyboard.press("ArrowDown");
  await expect(trigger).toHaveAttribute("aria-activedescendant", "look-option-2-1");
  await page.keyboard.press("Enter");
  await expect(picker.locator("[data-test='look-list']")).toBeHidden();
  await expect(trigger).toBeFocused();
  await expect(preview.locator("[data-test='look-preview-label']")).toHaveText("Demo Winger Delta > Away White");
  await expect(preview.locator("[data-test='look-preview-empty']")).toContainText("No character sheet yet");
  await expect(picker.locator("[data-test='swap-saved']")).toBeVisible();
  await expect(picker).toHaveAttribute("data-state", "recast");
  // Escape closes without changing the pick.
  await page.keyboard.press("ArrowDown");
  await expect(picker.locator("[data-test='look-list']")).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(picker.locator("[data-test='look-list']")).toBeHidden();
  await expect(trigger).toHaveText("Away White");

  // The last row opens the generate form on the card, and says what a press costs.
  await page.keyboard.press("Enter");
  await page.keyboard.press("End");
  await expect(trigger).toHaveAttribute("aria-activedescendant", "look-option-2-3");
  await page.keyboard.press("Enter");
  const form = picker.locator("[data-test='look-generate-form']");
  await expect(form).toBeVisible();
  await expect(form).toContainText("New look for Demo Winger Delta");
  await expect(form.locator("input[name='descriptor']")).toBeFocused();
  await expect(form.locator("[data-test='look-cost-hint']")).toContainText("Costs money: makes the look and builds one character sheet");
  await form.locator("input[name='descriptor']").fill(name);
  await form.locator("input[name='number']").fill("12");
  await form.getByRole("button", { name: "Generate look" }).click();

  // Back on the same card, cast in the new look while its sheet builds.
  await expect(page).toHaveURL(/\/music_videos\/test-cinematic-look-picker-demo\?look=look-[0-9a-f]+#person-2$/);
  await expect(card(page, 2)).toBeInViewport();
  await expect(picker).toHaveAttribute("data-state", "recast");
  await expect(trigger).toHaveText(name);
  await expect(preview.locator("[data-test='look-preview-label']")).toHaveText(`Demo Winger Delta > ${name}`);
  await expect(page.locator("[data-test='chunk-prompt']").filter({ hasText: `like the ${name} model provided` }).first()).toBeAttached();
  // The card repaints itself when the sheet is ready: no reload here.
  await expect(preview).toHaveAttribute("data-state", "ready", { timeout: 20000 });
  await expect(preview.locator("[data-test='look-preview-image']")).toBeVisible();
  await expect(preview.locator("[data-test='look-preview-state']")).toHaveText("Character sheet ready");
  await trigger.click();
  await expect(option(picker, name).locator("[data-test='look-thumb-image']")).toBeVisible();
  await expect(option(picker, name)).toHaveAttribute("aria-selected", "true");
  await page.keyboard.press("Escape");
});

test("a building look repaints in place when the poll says its sheet is ready, and an image that fails falls back to the placeholder", async ({ page }) => {
  await loginWithMagicLink(page, "alex@test.com");
  // The seeded building look has no job behind it: the poll's answer is rewritten here, once, to ready.
  let polls = 0;
  await page.route("**/recast_athletes/demo-winger-delta/looks.json", async (route) => {
    polls += 1;
    const rows = await (await route.fetch()).json();
    const building = rows.find((row) => row.descriptor === "Alternate Blue");
    Object.assign(building, { state: "ready", image_url: "/no-such-sheet.png" });
    await route.fulfill({ json: rows });
  });
  await page.goto(VIDEO);

  // A card not swapped: on reveals the search, and nothing is chosen until the search says so.
  const picker = recast(page, 1);
  if ((await picker.getAttribute("data-state")) !== "off") await picker.locator("[data-test='swap-toggle']").click();
  await expect(picker).toHaveAttribute("data-state", "off");
  await picker.locator("[data-test='swap-toggle']").click();
  await expect(picker).toHaveAttribute("data-state", "open");
  await expect(picker.locator("[data-test='look-picker']")).toBeHidden();
  await picker.getByRole("combobox").fill("demo");
  // The search row says what is saved for each person: the default look's sheet and name beside the count.
  const delta = picker.locator("[data-test='recast-option']").filter({ hasText: "Demo Winger Delta" });
  await expect(delta.locator("[data-test='search-row-badge']")).toHaveText(/^\d+ looks$/);
  await expect(delta.locator("[data-test='search-row-look-name']")).toHaveText("Home Orange");
  await expect(delta.locator("[data-test='search-row-look'] [data-test='look-thumb-image']")).toBeVisible();
  await expect(delta.locator("[data-test='search-row-avatar'] img")).toHaveCount(0);
  const novice = picker.locator("[data-test='recast-option']").filter({ hasText: "Demo Novice Echo" });
  await expect(novice.locator("[data-test='search-row-name']")).toBeVisible();
  if ((await novice.locator("[data-test='search-row-badge']").textContent()) === "0 looks") {
    await expect(novice.locator("[data-test='search-row-look']")).toBeHidden();
    await expect(novice.locator("[data-test='search-row-no-look']")).toHaveText("No look yet");
  }
  // At phone width the list stays on screen; the look drops under the name (the name keeps most of the row,
  // it may ellipsize under a wide font, never vanish), and the row does not spill past the list.
  await page.setViewportSize({ width: 390, height: 844 });
  await expect(delta.locator("[data-test='search-row-name']")).toBeVisible();
  expect(await delta.locator("[data-test='search-row-name']").evaluate((el) => el.clientWidth)).toBeGreaterThan(120);
  expect(await delta.evaluate((el) => el.scrollWidth <= el.clientWidth)).toBe(true);
  await expect(delta.locator("[data-test='search-row-look-name']")).toBeVisible();
  await page.waitForTimeout(100);
  const list = await picker.locator("[data-test='recast-results']").boundingBox();
  expect(list.x).toBeGreaterThanOrEqual(0);
  expect(list.x + list.width).toBeLessThanOrEqual(390);
  await page.setViewportSize({ width: 1280, height: 720 });
  await delta.click();

  // The pick saves him in his default look; the building one says so in its row and in the note.
  await expect(picker.locator("[data-test='look-preview-label']")).toHaveText("Demo Winger Delta > Home Orange");
  await expect(picker).toHaveAttribute("data-state", "recast");
  await expect(picker.locator("[data-test='swap-athlete-name']")).toHaveText("Demo Winger Delta");
  await picker.locator("[data-test='look-trigger']").click();
  await option(picker, "Alternate Blue").click();
  await expect(picker.locator("[data-test='swap-saved']")).toBeVisible();
  await expect(picker.locator("[data-test='look-preview']")).toHaveAttribute("data-state", /^(building|ready)$/);
  await expect(picker.locator("[data-test='look-cast-no-sheet']")).toBeVisible();

  // The poll lands: the same card, no reload, now reads ready. Its image 404s, so the placeholder stands in.
  await expect(picker.locator("[data-test='look-preview']")).toHaveAttribute("data-state", "ready", { timeout: 15000 });
  expect(polls).toBeGreaterThan(0);
  await expect(picker.locator("[data-test='look-preview-empty']")).toContainText("could not be loaded");
  await expect(picker.locator("[data-test='look-cast-no-sheet']")).toBeHidden();
  await expect(picker).toHaveAttribute("data-state", "recast");
});

test("an athlete with no look is offered generate first look, and the new look can be cast", async ({ page }) => {
  const name = `Training Grey ${Date.now()}`;
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto(VIDEO);

  const picker = recast(page, 3);
  await expect(picker).toHaveAttribute("data-state", "off");
  await picker.locator("[data-test='swap-toggle']").click();
  await picker.getByRole("combobox").fill("novice echo");
  const rookie = picker.locator("[data-test='recast-option']").filter({ hasText: "Demo Novice Echo" });
  await expect(rookie.locator("[data-test='search-row-badge']")).toHaveText("0 looks");
  await rookie.click();

  // The pick saves him alone, pending; the card offers the first look in place of a dropdown.
  await expect(picker).toHaveAttribute("data-state", "pending");
  await expect(picker.locator("[data-test='swap-athlete-name']")).toHaveText("Demo Novice Echo");
  await expect(picker.locator("[data-test='recast-no-look']")).toHaveText("Demo Novice Echo has no look yet.");
  await expect(picker.locator("[data-test='look-trigger']")).toBeHidden();
  const form = picker.locator("[data-test='look-generate-form']");
  await expect(form).toContainText("First look for Demo Novice Echo");
  await form.getByRole("button", { name: "Cancel" }).click();
  await expect(form).toBeHidden();
  await picker.getByRole("button", { name: "Generate first look" }).click();
  await expect(form.locator("input[name='descriptor']")).toBeFocused();
  await form.locator("input[name='descriptor']").fill(name);
  await form.getByRole("button", { name: "Generate look" }).click();

  // He is cast in his new first look, which is his default; the card is closed.
  await expect(picker).toHaveAttribute("data-state", "recast");
  await expect(card(page, 3)).toHaveAttribute("data-resolved", "true");
  const preview = picker.locator("[data-test='look-preview']");
  await expect(preview.locator("[data-test='look-preview-label']")).toHaveText(`Demo Novice Echo > ${name}`);
  await expect(preview).toHaveAttribute("data-state", "ready", { timeout: 20000 });
  await expect(preview.locator("[data-test='look-preview-image']")).toBeVisible();
  await picker.locator("[data-test='look-trigger']").click();
  await expect(option(picker, name).locator("[data-test='look-option-default']")).toBeVisible();
  await page.keyboard.press("Escape");
});
