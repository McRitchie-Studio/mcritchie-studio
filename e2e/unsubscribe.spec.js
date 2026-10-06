const { test, expect } = require("@playwright/test");
const { VISITOR } = require("./helpers");

// What a visitor sees: signed out, not the suite's default admin session.
test.use({ storageState: VISITOR });

// [e2e] The unsubscribe link in every broadcast, in a real browser: the page
// names the reader's address (never which email; that is captured, not shown),
// one red button unsubscribes, and the landing's violet button resubscribes. Seeded by e2e/seed.rb
// (reader@example.com, tokens e2e-unsubscribe-token / e2e-delivery-token).
const LINK = "/unsubscribe/e2e-unsubscribe-token?d=e2e-delivery-token";

test("a reader unsubscribes with one button, then changes their mind", async ({ page }) => {
  await page.goto(LINK);
  await expect(page.locator("[data-unsubscribe-email]")).toHaveText("reader@example.com");
  await expect(page.getByText("Cyvasse is back")).toHaveCount(0);

  await page.getByRole("button", { name: "Unsubscribe" }).click();
  await expect(page.getByRole("heading", { name: "You're unsubscribed" })).toBeVisible();
  await expect(page.locator("[data-unsubscribe-email]")).toHaveText("reader@example.com");

  await page.getByRole("button", { name: "Resubscribe" }).click();
  await expect(page.getByRole("heading", { name: "Welcome back" })).toBeVisible();

  // The link from the email still works afterwards: back to a plain Unsubscribe.
  await page.goto(LINK);
  await expect(page.getByRole("heading", { name: "Unsubscribe?" })).toBeVisible();
});
