const { test, expect } = require("@playwright/test");
const { loginWithMagicLink, blockThirdPartyRequests } = require("./helpers");

// [e2e] /s/cyvasse-first-game — the first-game survey the way a reader walks it
// on a phone (task first-game-feedback-survey), then the answer on the admin view.
//
// What only a browser proves: the faces are real tap targets although their
// radios are visually hidden, the page fits a phone with no sideways scroll,
// the bot trap is out of a person's reach, the token survives the round trip
// (thank-you, then back to edit with the face still picked), and the admin
// table credits the answer to the email's reader. The reader and their token
// ("e2e-survey-token") come from e2e/seed.rb.

test("a reader answers the survey on a phone, edits it, and the admin sees it credited", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await blockThirdPartyRequests(page);
  await page.goto("/s/cyvasse-first-game?t=e2e-survey-token");

  await expect(page.getByRole("heading", { name: "Your first game on the new Cyvasse", level: 1 })).toBeVisible();
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
  expect(overflow).toBeLessThanOrEqual(0);

  // The bot trap is on the page but out of reach.
  const trap = page.locator("[data-test='survey-honeypot']");
  await expect(trap).toHaveCount(1);
  await expect(trap).toHaveAttribute("tabindex", "-1");
  await expect(trap).not.toBeInViewport();

  // Tapping a face picks it; the five faces sit in one row.
  const loved = page.locator("[data-test='survey-option-feeling-5']");
  await page.locator("label:has([data-test='survey-option-feeling-5'])").click();
  await expect(loved).toBeChecked();
  const tops = await page.locator("[data-test='survey-question-feeling'] label").evaluateAll(
    (labels) => labels.map((label) => Math.round(label.getBoundingClientRect().top))
  );
  expect(new Set(tops).size).toBe(1);

  await page.getByLabel("What did you enjoy most?").fill("Live games against real people");
  await page.locator("label:has([data-test='survey-option-play_again-yes'])").click();
  await page.locator("[data-test='survey-submit']").click();

  await expect(page.locator("[data-test='survey-thanks']")).toContainText("Thank you");
  await expect(page.locator("[data-test='survey-play']")).toHaveAttribute("href", "https://cyvasse.xyz/?ref=e2e-survey-token");

  // Back to edit: the stored answers are there, and saving keeps one response.
  await page.locator("[data-test='survey-edit']").click();
  await expect(page.locator("[data-test='survey-editing']")).toBeVisible();
  await expect(loved).toBeChecked();
  await expect(page.getByLabel("What did you enjoy most?")).toHaveValue("Live games against real people");
  await page.locator("label:has([data-test='survey-option-feeling-4'])").click();
  await page.locator("[data-test='survey-submit']").click();
  await expect(page.locator("[data-test='survey-thanks']")).toBeVisible();

  // The admin view credits it to the reader, once, with the edited feeling.
  await page.setViewportSize({ width: 1280, height: 900 });
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/surveys/cyvasse-first-game");
  await expect(page.locator("[data-test='survey-count']")).toHaveText("1");
  const row = page.locator("[data-test='survey-answer-row']");
  await expect(row).toHaveCount(1);
  await expect(row).toContainText("survey-reader@example.com");
  await expect(row).toContainText("e2e_first_gamer");
  await expect(row).toContainText("🙂 Good");
  await expect(page.locator("[data-test='survey-feeling-4']")).toContainText("1");
});
