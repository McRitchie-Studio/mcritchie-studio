const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

// [e2e] An admin opens a header brief for Turf's drop-signup confirmation
// (new player), generates a round with the E2E fake generator
// (E2E_FAKE_IMAGE_GENERATION=1: no vendor, no bucket), approves one candidate,
// and sees it inside the real email shell.
//
// NOT @qa-readonly: it writes a brief and approves a candidate.

test("admin briefs, generates, approves and previews an email header", async ({ page }) => {
  await loginWithMagicLink(page, "alex@test.com");

  await page.goto("/email_images");
  await expect(page.getByRole("heading", { name: "Email images" })).toBeVisible();

  const form = page.locator("[data-test='brief-form']");
  await form.locator("select[name='email_image_brief[app]']").selectOption("turf-monster");
  await form.locator("input[name='email_image_brief[email_key]']").fill("drop_signup_confirmation");
  await form.locator("input[name='email_image_brief[variant]']").fill("new_player");
  await form.locator("select[name='email_image_brief[brand_kit]']").selectOption("turf-monster");
  await form.locator("input[name='email_image_brief[headline]']").fill("You're In!");
  await form.getByRole("button", { name: "Open brief" }).click();

  await expect(page).toHaveURL(/\/email_images\/turf-monster-drop-signup-confirmation-new-player$/);
  await expect(page.locator("[data-test='no-candidates']")).toBeVisible();

  await page.locator("[data-test='generate-form'] button").click();
  await expect(page.locator("[data-test='build-status']")).toBeVisible();

  // The fake round runs async in the server; poll the page until it lands.
  await expect(async () => {
    await page.reload();
    await expect(page.locator("[data-test='candidate']")).toHaveCount(2, { timeout: 1_000 });
  }).toPass({ timeout: 30_000 });
  await expect(page.locator("[data-test='rounds']")).toContainText("1 of 4");
  await expect(page.locator("[data-test='spend']")).toContainText("tokens");

  const first = page.locator("[data-test='candidate']").first();
  const slug = await first.getAttribute("data-slug");
  await first.locator("[data-test='approve-form'] button").click();

  const approved = page.locator(`[data-test='candidate'][data-slug='${slug}']`);
  await expect(approved).toHaveAttribute("data-state", "approved");
  await expect(approved.locator("[data-test='approved-badge']")).toBeVisible();

  // The preview is the engine's email shell, framed at email width, showing
  // the approved candidate with the headline as its alt text.
  const frame = page.frameLocator("[data-test='email-preview']");
  await expect(frame.locator("[data-test='email-shell']")).toBeVisible();
  const header = frame.locator("img[width='600']").first();
  await expect(header).toHaveAttribute("alt", "You're In!");
  await expect(frame.locator("body")).toContainText(slug);
});
