const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

// [e2e] An admin opens the Turf Monster brand kit, sees its base references,
// palette and style rules, uploads a PNG reference with a role, label and note,
// and sees it listed as an uploaded reference that a round will send.
// E2E_FAKE_IMAGE_GENERATION=1 keeps the upload off any bucket: the shared store
// answers the data URI it was handed.
//
// NOT @qa-readonly: it writes an email_brand_references row.

// A 2x2 green PNG, built in the spec so no fixture file is needed.
const PNG = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAFklEQVQI12PUqzViYGBgYmBgYGBgAAAKggDhbzHdAQAAAABJRU5ErkJggg==",
  "base64"
);

test("admin opens the turf kit, uploads a reference and sees it listed", async ({ page }) => {
  await loginWithMagicLink(page, "alex@test.com");

  await page.goto("/email_images");
  await page.locator("[data-test='brand-kits-link']").click();
  await expect(page.getByRole("heading", { name: "Brand kits" })).toBeVisible();
  await page.locator("[data-test='brand-kit-card'][data-kit='turf-monster']").click();

  await expect(page).toHaveURL(/\/email_images\/brand_kits\/turf-monster$/);
  await expect(page.getByRole("heading", { name: "Turf Monster" })).toBeVisible();
  await expect(page.locator("[data-test='reference'][data-origin='yaml']")).toHaveCount(2);
  await expect(page.locator("[data-test='kit-palette']")).toContainText("#2E7D32");
  await expect(page.locator("[data-test='kit-never']")).toContainText("No real people");
  await expect(page.locator("[data-test='likeness-guard']")).toContainText("No photos of real people");

  const form = page.locator("[data-test='reference-form']");
  await form.locator("input[type='file']").setInputFiles({ name: "gator-wave.png", mimeType: "image/png", buffer: PNG });
  await form.locator("select[name='email_brand_reference[role]']").selectOption("mascot");
  await form.locator("input[name='email_brand_reference[label]']").fill("Gator wave");
  await form.locator("textarea[name='email_brand_reference[note]']").fill("use this pose");
  await form.getByRole("button", { name: "Add reference" }).click();

  await expect(page).toHaveURL(/\/email_images\/brand_kits\/turf-monster$/);
  const uploaded = page.locator("[data-test='reference'][data-origin='upload']");
  await expect(uploaded).toHaveCount(1);
  await expect(uploaded.locator("[data-test='reference-label']")).toHaveText("Gator wave");
  await expect(uploaded.locator("[data-test='reference-note']")).toContainText("use this pose");
  await expect(uploaded.locator("[data-test='sent-badge']")).toHaveText("sent #3");
  await expect(uploaded.locator("img")).toHaveJSProperty("naturalWidth", 2);
});
