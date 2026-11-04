// [e2e] /contact: one page for the chat with Alex and the carrier-reviewed SMS opt-in.
//
// What only a browser can prove: on arrival, at desktop and at 390px, the chat and
// the form are both showing with no click, the disclosure is visible, and nothing
// runs sideways. A refused submission (Turbo scrolls to the top on a 422) and a
// card link reach the form without the visitor having to find it under the chat.
const { test, expect } = require("@playwright/test");
const { VISITOR } = require("./helpers");

test.use({ storageState: VISITOR });

const CHAT = "[data-studio-controller='agent-chat']";
const FORM = "form[data-test='contact-form']";
const sideways = (page) => page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);

for (const [label, viewport] of [["desktop", { width: 1280, height: 800 }], ["390px", { width: 390, height: 844 }]]) {
  test.describe(label, () => {
    test.use({ viewport });

    test("chat and form both show on arrival, with no click and nothing sideways", async ({ page }) => {
      await page.goto("/contact");

      await expect(page.locator(CHAT)).toHaveAttribute("data-agent-chat-ready", "true");
      await expect(page.locator("[data-test='agent-chat-empty']")).toHaveText("What brought you here today?");
      await expect(page.locator("[data-test='agent-chat-input']")).toBeInViewport();
      await expect(page.locator("[data-test='contact-form-column']")).toBeInViewport();

      for (const hook of ["contact-consent", "sms-disclosure", "contact-submit", "contact-other-ways"]) {
        await expect(page.locator(`[data-test='${hook}']`)).toBeVisible();
      }
      expect(await sideways(page)).toBeLessThanOrEqual(0);
    });

    test("a long thread does not hold the page: the wheel over it still moves the page", async ({ page }) => {
      await page.goto("/contact");
      await expect(page.locator(CHAT)).toHaveAttribute("data-agent-chat-ready", "true");
      // A tall thread, as a returning person's would be. The wheel lands on the thread and the
      // page must still move once the thread has reached its end.
      const log = page.locator("[data-test='agent-chat-messages']");
      await log.evaluate((el) => { el.innerHTML = `<div style="height:3000px">long thread</div>`; el.scrollTop = el.scrollHeight; });
      const box = await log.boundingBox();
      expect(box.height).toBeLessThanOrEqual(viewport.height * 0.4 + 1);
      await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
      await page.mouse.wheel(0, 400);
      await expect.poll(() => page.evaluate(() => window.scrollY)).toBeGreaterThan(0);
    });

    test("a refused submission reaches its errors, over the chat", async ({ page }) => {
      await page.goto("/contact");
      await expect(page.locator("[data-test='contact-proof']")).not.toHaveValue("");
      await page.getByLabel("Name", { exact: true }).fill("Jordan Lee");
      await page.getByLabel("Email", { exact: true }).fill("jordan@example.test");
      // Whitespace passes the browser's `required` and fails the model's presence check.
      await page.getByLabel("Message", { exact: true }).fill("   ");
      await page.locator("[data-test='contact-submit']").click();

      const errors = page.locator("[data-test='contact-errors']");
      await expect(errors).toBeVisible();
      await expect(errors).toBeInViewport();
      // The form was re-rendered by Turbo: the chat below it must still be wired up.
      await expect(page.locator(CHAT)).toHaveAttribute("data-agent-chat-ready", "true");
      expect(await sideways(page)).toBeLessThanOrEqual(0);
    });

    test("a card link lands on the form with its message and hidden source", async ({ page }) => {
      await page.goto("/contact?source[page]=integrations&source[item]=github&source[intent]=connect");

      await expect(page.locator(FORM)).toBeInViewport();
      await expect(page.locator("[data-test='contact-source'][data-source-key='item']")).toHaveValue("github");
    });
  });
}

test("/chat lands on the contact page", async ({ page }) => {
  await page.goto("/chat");
  await expect(page).toHaveURL(/\/contact$/);
  await expect(page.locator(CHAT)).toBeVisible();
  await expect(page.locator(FORM)).toBeVisible();
});
