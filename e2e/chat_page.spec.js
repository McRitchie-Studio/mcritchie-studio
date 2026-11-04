// [e2e] /chat is only the chat, with one quiet link to the SMS sign-up; /contact is
// only the carrier-reviewed form. Each spec is a bare test(), one per width: the
// census counts declarations, so a test() in a loop reads as one.
const { test, expect } = require("@playwright/test");
const { VISITOR } = require("./helpers");

test.use({ storageState: VISITOR });

const DESKTOP = { width: 1280, height: 800 };
const PHONE = { width: 390, height: 844 };
const CHAT = "[data-studio-controller='agent-chat']";
const LINK = "[data-test='chat-sms-signup']";
const sideways = (page) => page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);

async function chatPageIsOnlyTheChat(page, viewport) {
  await page.setViewportSize(viewport);
  await page.goto("/chat");

  await expect(page.locator(CHAT)).toHaveAttribute("data-agent-chat-ready", "true");
  await expect(page.locator("[data-test='agent-chat-empty']")).toHaveText("What brought you here today?");
  await expect(page.locator("[data-test='chat-heading']")).toHaveText("How Can I Help?");
  await expect(page.locator("[data-test='agent-chat-caption']")).toContainText("AI Builder");
  // The heading stands over an empty thread and leaves with the first turn.
  await page.locator("[data-agent-chat-log]").evaluate((log) => log.append(document.createElement("div")));
  await expect(page.locator("[data-test='chat-heading']")).toBeHidden();
  await page.locator("[data-agent-chat-log] > div").last().evaluate((turn) => turn.remove());
  await expect(page.locator("[data-test='agent-chat-input']")).toBeInViewport();
  await expect(page.locator("[data-test='contact-form']")).toHaveCount(0);
  await expect(page.locator("[data-test='sms-disclosure']")).toHaveCount(0);
  await expect(page.locator(LINK)).toBeVisible();
  // WCAG 2.2 AA target size: the link is a phone user's only way to the form from here.
  expect((await page.locator(LINK).boundingBox()).height).toBeGreaterThanOrEqual(24);
  expect(await sideways(page)).toBeLessThanOrEqual(0);
}

async function signUpLinkReachesTheForm(page, viewport) {
  await page.setViewportSize(viewport);
  await page.goto("/chat");
  await page.locator(LINK).click();

  await expect(page).toHaveURL(/\/contact$/);
  await expect(page.locator("[data-test='contact-form']")).toBeInViewport();
  for (const hook of ["contact-consent", "sms-disclosure", "contact-submit"]) {
    await expect(page.locator(`[data-test='${hook}']`)).toBeVisible();
  }
  await expect(page.locator(CHAT)).toHaveCount(0);
  expect(await sideways(page)).toBeLessThanOrEqual(0);
}

test("desktop: /chat is only the chat and its sign-up link", async ({ page }) => {
  await chatPageIsOnlyTheChat(page, DESKTOP);
});

test("390px: /chat is only the chat and its sign-up link", async ({ page }) => {
  await chatPageIsOnlyTheChat(page, PHONE);
});

test("desktop: the sign-up link reaches the form and disclosure, with no click to open them", async ({ page }) => {
  await signUpLinkReachesTheForm(page, DESKTOP);
});

test("390px: the sign-up link reaches the form and disclosure, with no click to open them", async ({ page }) => {
  await signUpLinkReachesTheForm(page, PHONE);
});
