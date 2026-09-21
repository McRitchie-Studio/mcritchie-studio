const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

// [e2e] The rapper-replace inspection gate, happy path: an operator opens a
// qualifying duo, sees which artifacts are reusable, and approves.
//
// NOT @qa-readonly on purpose. This spec depends on seeded artifacts and it
// WRITES (it approves). @qa-readonly specs are run against live QA and prod by
// bin/prod-smoke, where seeded rows do not exist and an approval would be a
// real mutation.
test("operator approves the three artifacts and the gate closes", async ({ page }) => {
  await loginWithMagicLink(page, "alex@test.com");

  await page.goto("/contents");
  await page.click("text=E2E Burrow And Chase");

  // The gate is present, with its three named slots.
  const gate = page.locator("text=Artifact Inspection").first();
  await expect(gate).toBeVisible();
  await expect(page.locator("body")).toContainText("Both players");
  await expect(page.locator("body")).toContainText("Quarterback");
  await expect(page.locator("body")).toContainText("Skill player");

  // The decision mix the seed sets up: two already on file in this jersey, one
  // on file in another. The re-skin is the whole point — we have Chase, just
  // not in white.
  await expect(page.locator("body")).toContainText("REUSE");
  await expect(page.locator("body")).toContainText("RE-SKIN");

  // The jersey is a GUESS until confirmed, and says so.
  await expect(page.locator("body")).toContainText("GUESSED FROM HOME/AWAY");

  // Attach the missing skill sheet in this game's colorway, which is what makes
  // all three slots complete.
  const skillForm = page.locator("form:has(input[value='skill_sheet'])");
  await skillForm.locator("input[name='image_url']").fill("/demo-artifacts/demo-3.png");
  await skillForm.locator("input[type='submit']").click();

  // Approve.
  page.on("dialog", (d) => d.accept());
  await page.click("text=Approve all three");

  // The gate closes once approved — that is the signal video is unlocked.
  await expect(page.locator("text=Artifact Inspection")).toHaveCount(0);
});
