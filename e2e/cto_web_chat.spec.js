// [e2e] The CTO web chat (docs/agents/system/agent-message-loop.md, "Web chat").
// The admin (linked to an owner-role person by e2e/seed.rb) opens Turf's chat,
// sends with Enter, and the message appears. The spec then plays the dispatcher
// through the real mailbox API: claim, a typing pulse, the answer. Over the real
// ActionCable stream (CABLE_ADAPTER=async, E2E_WEB_CHAT_JOBS=1) the page shows
// "Turf is typing…", then the answer, with no reload, and typing clears. The
// meter is in tokens; the page fits a phone; the bubbles read in both themes.
// An owner whom the CTO does not answer yet is told so, and their turn is held.
//
// NOT @qa-readonly: it writes agent messages. Nothing here talks to Discord or Claude.
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink, watchPageErrors, VISITOR } = require("./helpers");
const { CONTRAST, eachTheme, TEXT_ON_SURFACE } = require("./contrast");

test.use({ storageState: VISITOR });

async function apiToken(page) {
  await page.goto("/agents/activities");
  return page.getAttribute("meta[name='e2e-api-token']", "content");
}

test("the owner chats with Turf: typing shows live, then the answer streams in", async ({ page }) => {
  const { pageErrors, report } = watchPageErrors(page);
  await loginWithMagicLink(page, "alex@test.com");
  const token = await apiToken(page);
  const auth = { Authorization: `Bearer ${token}`, "Content-Type": "application/json" };
  const worker = `e2e-web-${Date.now()}`;

  await page.goto("/applications/turf-monster");
  await page.locator("[data-test='application-cto-chat']").click();
  await expect(page).toHaveURL(/\/applications\/turf-monster\/chat$/);
  await expect(page.getByRole("heading", { name: "Chat with Turf" })).toBeVisible();
  await expect(page.locator("turbo-cable-stream-source[channel='CtoChatChannel']")).toHaveAttribute("connected", "");
  await expect(page.locator("[data-test='cto-chat-usage'] [data-test='usage-meter']")).toBeVisible();
  await expect(page.locator("[data-test='cto-chat-usage']")).not.toContainText("$");

  const text = `How are signups? ${Date.now()}`;
  const input = page.locator("[data-test='cto-chat-input']");
  await input.fill(text);
  await input.press("Enter");
  const turn = page.locator("[data-test='cto-chat-turn']", { hasText: text });
  await expect(turn).toHaveCount(1);
  await expect(turn).toHaveAttribute("data-status", "received");
  await expect(input).toHaveValue("");

  // The dispatcher's side, through the real API: claim, then one typing pulse.
  const claimed = await page.request.post("/api/v1/agent_messages/claim", {
    headers: auth, data: { souls: ["turf_monster"], worker, channel: "web" },
  });
  expect(claimed.ok()).toBeTruthy();
  const message = (await claimed.json()).data;
  expect(message.content).toBe(text);

  const typing = await page.request.post(`/api/v1/agent_messages/${message.id}/typing`, { headers: auth, data: { worker } });
  expect((await typing.json()).meta.typing).toBe("queued");
  const pulse = page.locator("#cto-chat-typing [data-test='cto-chat-typing']");
  await expect(pulse).toContainText("Turf is typing");
  // A second pulse lands in the same slot (the dispatcher pulses every 7s while it runs).
  const firstAt = await pulse.getAttribute("data-typing-at");
  const again = await page.request.post(`/api/v1/agent_messages/${message.id}/typing`, { headers: auth, data: { worker } });
  expect((await again.json()).meta.typing).toBe("queued");
  await expect(pulse).not.toHaveAttribute("data-typing-at", firstAt);

  const done = await page.request.post(`/api/v1/agent_messages/${message.id}/complete`, {
    headers: auth, data: { worker, response_text: "**Twelve** signups this week." },
  });
  expect(done.ok()).toBeTruthy();

  const reply = turn.locator("[data-test='cto-chat-reply']");
  await expect(reply).toContainText("Twelve signups this week.");
  await expect(reply.locator("strong")).toHaveText("Twelve");
  await expect(turn).toHaveAttribute("data-status", "completed");
  await expect(page.locator("[data-test='cto-chat-typing']")).toHaveCount(0);

  // The thread persists: a reload shows the same turn, answered.
  await page.reload();
  await expect(page.locator("[data-test='cto-chat-turn']", { hasText: text }).locator("[data-test='cto-chat-reply']")).toBeVisible();

  // Both themes: the sent bubble, the answer and the meter line read.
  await eachTheme(page, async (theme) => {
    for (const selector of ["[data-test='cto-chat-sent']", "[data-test='cto-chat-reply'] p", "[data-test='usage-meter-line']"]) {
      const measured = await page.evaluate(CONTRAST, selector);
      expect(measured.length, `${theme}: ${selector} renders`).toBeGreaterThan(0);
      for (const m of measured) expect(m.ratio, `${theme}: ${selector} "${m.text}"`).toBeGreaterThanOrEqual(TEXT_ON_SURFACE);
    }
  });

  // A phone: nothing runs off the side, and the composer is on screen.
  await page.setViewportSize({ width: 390, height: 844 });
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
  expect(overflow, "nothing runs off the side at 390px").toBeLessThanOrEqual(0);
  await expect(page.locator("[data-test='cto-chat-send']")).toBeInViewport();

  expect(pageErrors, report()).toHaveLength(0);
});

test("an owner the CTO does not answer yet is told so, and their message is held", async ({ page }) => {
  await loginWithMagicLink(page, "owner@turf.test");
  await page.goto("/applications/turf-monster/chat");

  await expect(page.locator("[data-test='cto-chat-unanswered']")).toContainText("does not answer your account yet");
  const input = page.locator("[data-test='cto-chat-input']");
  await input.fill("Hello Turf");
  await page.locator("[data-test='cto-chat-send']").click();
  const turn = page.locator("[data-test='cto-chat-turn']", { hasText: "Hello Turf" });
  await expect(turn).toHaveAttribute("data-status", "held");
  await expect(turn.locator("[data-test='cto-chat-held']")).toContainText("Waiting for an admin");

  // Another app's chat does not exist for this owner.
  const other = await page.goto("/applications/mcritchie-studio/chat");
  expect(other.status()).toBe(404);
});
