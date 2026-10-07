// [e2e] The iced-out twin and a person's jewelry, on the person page. The
// operator adds a (synthetic) championship ring, gives an older look its iced
// twin, creates a new look and sees it land beside its own twin, then opens the
// twin's page, which says it is the iced twin and builds the iced sheet. Nothing
// here builds a sheet: making a look or a twin is a free row. Seeded by
// e2e/seed.rb (Novice Icefixture).
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

const PERSON = "/people/novice-icefixture";

test("operator adds a ring, creates a look, and sees each look beside its iced twin", async ({ page }) => {
  const name = `Comets navy ${Date.now()}`;
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto(PERSON);

  // Jewelry: none yet, then a ring with its year and the text the prompt uses.
  const jewelry = page.locator("[data-test='jewelry-card']");
  await jewelry.locator("[data-test='jewelry-new'] summary").click();
  const form = jewelry.locator("[data-test='jewelry-form']");
  await form.getByLabel("Kind").selectOption("super_bowl_ring");
  await form.getByLabel("Name").fill("Big Game XC ring");
  await form.getByLabel("Year (rings)").fill("2031");
  await form.getByLabel(/What it looks like/).fill("white gold, a pavé comet on a blue stone face");
  await form.getByRole("button", { name: "Add jewelry" }).click();
  const ring = page.locator("[data-test='jewelry-row'][data-kind='super_bowl_ring']");
  await expect(ring).toContainText("2031 Big Game XC ring");
  await expect(ring).toContainText("white gold, a pavé comet on a blue stone face");

  // The older look gets its twin on request, listed straight after it.
  const older = page.locator("[data-test='person-look']").filter({ hasText: "Comets white" }).first();
  await older.locator("[data-test='create-iced-twin']").click();
  const looks = page.locator("[data-test='person-look']");
  await expect(looks.filter({ hasText: "Comets white · iced" })).toHaveAttribute("data-iced", "true");
  await expect(page.locator("[data-test='person-look'][data-iced='false']").filter({ hasText: "Comets white" })
    .locator("[data-test='create-iced-twin']")).toHaveCount(0);

  // A new look brings its own twin.
  await page.locator("[data-test='new-model'] summary").click();
  await page.locator("[data-test='new-model'] input[name='appearance[descriptor]']").fill(name);
  await page.getByRole("button", { name: "Save model" }).click();
  await expect(page.locator("body")).toContainText(`with its iced twin ${name} · iced. No sheet was built.`);
  const names = await looks.evaluateAll((rows) => rows.map((row) => row.querySelector("span").textContent.trim()));
  expect(names).toEqual(["Comets white", "Comets white · iced", name, `${name} · iced`]);

  // The twin's page names its base and builds the iced sheet.
  await looks.filter({ hasText: `${name} · iced` }).locator("[data-test='character-model-link']").click();
  await expect(page).toHaveURL(/\/people\/novice-icefixture\/models\/look-[0-9a-f]+$/);
  await expect(page.locator("[data-test='twin-base']")).toBeVisible();
  await expect(page.locator("[data-test='iced-badge']")).toHaveText("iced");
  await expect(page.locator("[data-test='twin-base']")).toContainText(`Iced-out twin of ${name}`);
  await expect(page.locator("[data-test='twin-base']")).toContainText("1 jewelry record");
});
