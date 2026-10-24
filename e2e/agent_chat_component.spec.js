// [e2e] The shared agent chat's script (app/javascript/agent_chat.js), on its first
// page, the CTO chat. e2e/cto_web_chat.spec.js covers the live loop; this one pins
// what the module itself does in a browser: Shift+Enter is a new line and sends
// nothing, Enter sends, the fresh composer keeps focus, the log sits at its newest
// turn, and the old "cto_chat" import still resolves to the same module.
//
// NOT @qa-readonly: it writes agent messages (Cyvasse's owner, answered by the
// app-owner rule; their rows wait for tyrion, which no spec claims).
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink, watchPageErrors, VISITOR } = require("./helpers");

test.use({ storageState: VISITOR });

test("the shared chat script: Shift+Enter is a new line, Enter sends, focus stays, the log follows", async ({ page }) => {
  const { pageErrors, report } = watchPageErrors(page);
  await loginWithMagicLink(page, "owner@cyvasse.test");
  await page.goto("/applications/cyvasse/chat");

  const imports = await page.evaluate(() => JSON.parse(document.querySelector("script[type='importmap']").textContent).imports);
  expect(imports.cto_chat, "the old import name is pinned").toBeTruthy();
  expect(imports.cto_chat).toBe(imports.agent_chat);

  const turns = page.locator("[data-test='cto-chat-turn']");
  const before = await turns.count();
  const input = page.locator("[data-test='cto-chat-input']");
  const text = `Two lines ${Date.now()}`;
  await input.click();
  await input.pressSequentially(text);
  await input.press("Shift+Enter");
  await input.pressSequentially("second line");
  await expect(input).toHaveValue(`${text}\nsecond line`);
  await expect(turns).toHaveCount(before);

  await input.press("Enter");
  const turn = page.locator("[data-test='cto-chat-turn']", { hasText: text });
  await expect(turn).toHaveAttribute("data-status", "received");
  await expect(turn.locator("[data-test='cto-chat-sent']")).toHaveText(`${text}\nsecond line`);
  await expect(turns).toHaveCount(before + 1);

  // The composer is replaced after the send; the script puts the caret back in it.
  await expect(page.locator("[data-test='cto-chat-input']")).toBeFocused();
  await expect(page.locator("[data-test='cto-chat-input']")).toHaveValue("");

  // The log scrolled to the newest turn after the stream render.
  await expect.poll(() => page.evaluate(() => {
    const log = document.querySelector("[data-cto-chat-scroll]");
    return log.scrollHeight - log.clientHeight - log.scrollTop;
  })).toBeLessThanOrEqual(2);

  expect(pageErrors, report()).toEqual([]);
});
