const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

// [e2e] The model library and the inspection gate, on the Person-anchored model.
//
// NOT @qa-readonly on purpose: this depends on seeded people and it WRITES
// (it approves). @qa-readonly specs run against live QA and prod via
// bin/prod-smoke, where the seed does not exist and an approval would be real.

test("a person's model library shows their looks and every image they appear in", async ({ page }) => {
  await page.goto("/people/joe-burrow");

  await expect(page.locator("body")).toContainText("Joe Burrow");
  await expect(page.locator("body")).toContainText("Models");

  // The first look created is the default; a second one is not.
  //
  // SELECTED BY ITS HANDLE, not by its label. This used to read
  // `toContainText("DEFAULT")`, which bound the spec to a shouty spelling of a
  // badge — so re-theming that chip onto the engine's status roles (one page,
  // one spelling for "approved") turned a presentation change into a red e2e
  // lane. The claim the spec actually makes is "exactly one of these two looks
  // is the default", and that is what it now asserts.
  await expect(page.locator("body")).toContainText("Bengals white");
  await expect(page.locator("body")).toContainText("Navy suit");
  await expect(page.locator("[data-test='default-look-badge']")).toHaveCount(1);

  // Images include ones SHARED with someone else — the pair shows on both
  // people's pages, which is the point of reading through the subject join.
  await expect(page.locator("body")).toContainText("Joe Burrow + JaMarr Chase");
});

test("operator approves the artifacts and the gate closes", async ({ page }) => {
  await loginWithMagicLink(page, "alex@test.com");

  await page.goto("/contents");
  await page.click("text=E2E Burrow And Chase");

  await expect(page.locator("body")).toContainText("Artifact Inspection");
  await expect(page.locator("body")).toContainText("Both players");

  // Two artifacts are on file in this jersey, one slot is not — the mix the
  // screen exists to show.
  await expect(page.locator("body")).toContainText("REUSE");
  await expect(page.locator("body")).toContainText("GENERATE");

  // The jersey is a GUESS until confirmed, and says so out loud.
  await expect(page.locator("body")).toContainText("GUESSED FROM HOME/AWAY");

  // Fill the one empty slot, targeted by its cast rather than by position —
  // a positional selector picked the wrong form and the failure looked like a
  // disabled button rather than a mis-selected one.
  const skillForm = page.locator("form[data-slot-decision='generate']");
  await expect(skillForm).toHaveCount(1);
  await skillForm.locator("input[name='image_url']").fill("/icon.png");

  // Turbo submits asynchronously, so wait for the POST to actually land —
  // asserting straight after the click raced the request and read the OLD page.
  await Promise.all([
    page.waitForResponse((r) => r.url().includes("/attach_artifact") && r.request().method() === "POST"),
    skillForm.locator("input[type='submit']").click(),
  ]);

  // The slot must actually flip before approving means anything.
  await expect(page.locator("body")).not.toContainText("GENERATE");

  page.on("dialog", (d) => d.accept());
  await page.click("text=Approve all three");

  // The gate closing is the signal that video generation is unlocked.
  await expect(page.locator("text=Artifact Inspection")).toHaveCount(0);
});
