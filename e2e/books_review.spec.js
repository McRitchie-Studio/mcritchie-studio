// [e2e] /books (task mack-finance-seat) — an admin answers a waiting book line
// on the review page, sees it under Answered recently with who gave it, and
// undoes the answer. Account numbers stay cut to their last four.
//
// Lines come from e2e/seed.rb (synthetic Industries lines on its configured
// checking account). No Drive, no production: the page only records answers.
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

test("admin answers a waiting line, sees who answered it, and undoes it", async ({ page }) => {
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/books?entity=industries");

  await expect(page.getByRole("heading", { name: "Books", exact: true })).toBeVisible();
  const line = page.locator("[data-test='books-line']", { hasText: "OUTGOING FEDWIRETRANSFER" });
  await expect(line.locator("[data-test='books-line-account']")).toHaveText("Checking ···8760");
  await expect(line.locator("[data-test='books-line-amount']")).toHaveText("($5,000.00)");
  await expect(page.locator("body")).not.toContainText("99887766554433");

  // Answer the wire as a distribution with a purpose and a cited note.
  await line.locator("[data-test='books-line-category']").selectOption("member_distribution");
  await line.locator("[data-test='books-line-purpose']").fill("Owner draws");
  await line.locator("[data-test='books-line-note']").fill("Alex McRitchie 2026-10-28: a draw");
  await line.locator("[data-test='books-line-save']").click();

  await expect(page.locator("[data-test='books-waiting-empty']")).toBeVisible();
  const answered = page.locator("[data-test='books-recent-line']", { hasText: "OUTGOING FEDWIRETRANSFER" });
  await expect(answered.locator("[data-test='books-recent-category']")).toHaveText("Member distribution");
  await expect(answered.locator("[data-test='books-recent-by']")).toContainText("by alex@test.com");
  await expect(answered).toContainText("Owner draws");

  // Undo returns it to the lines waiting.
  page.once("dialog", (dialog) => dialog.accept());
  await answered.locator("[data-test='books-recent-undo'] button, [data-test='books-recent-undo'] input[type=submit]").click();
  await expect(page.locator("[data-test='books-line']", { hasText: "OUTGOING FEDWIRETRANSFER" })).toBeVisible();
  await expect(page.locator("[data-test='books-recent-line']", { hasText: "OUTGOING FEDWIRETRANSFER" })).toHaveCount(0);
});
