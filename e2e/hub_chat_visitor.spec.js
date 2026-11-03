const { test, expect } = require("@playwright/test");
const { VISITOR } = require("./helpers");

// [e2e] A signed-out visitor opens /chat and sends a message.
test.use({ storageState: VISITOR });

test("a visitor sends Alex a message from /chat", async ({ page }) => {
  await page.goto("/chat");
  const box = page.locator("[data-test='alex-chat-page'] textarea").first();
  await box.fill("What can you build for me?");
  await box.press("Enter");
  await expect(page.locator("[data-test='alex-chat-page']")).toContainText("What can you build for me?");
});
