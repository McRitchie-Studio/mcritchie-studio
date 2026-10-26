// [e2e] The CTO web chat (docs/agents/system/agent-message-loop.md, "Web chat").
// The admin (linked to an owner-role person by e2e/seed.rb) opens Turf's chat,
// sends with Enter, and the message appears. The spec then plays the dispatcher
// through the real mailbox API: claim, a thinking pulse, a typing pulse, the
// answer. Over the real ActionCable stream (CABLE_ADAPTER=async,
// E2E_WEB_CHAT_JOBS=1) the page shows "Turf is thinking", then "Turf is typing"
// in the same space, then the answer, with no reload, and typing clears. The
// meter is in tokens; the page fits a phone; the bubbles read in both themes.
// An app's owner is answered on their own app's chat (the app-owner rule), with
// no "not answered" notice, and another app's chat does not exist for them; and
// an owner who is not Alex McRitchie says go on a proposal there and sees the designed task.
//
// NOT @qa-readonly: it writes agent messages. Nothing here talks to Discord or Claude.
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink, watchPageErrors, VISITOR } = require("./helpers");
const { CONTRAST, eachTheme, TEXT_ON_SURFACE } = require("./contrast");
const { ADMIN_STATE } = require("./global-setup");

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
  // The agent shell: the CTO's portrait and name on top, the app's status card
  // (Building · Releasing · Deploying, then the tokens this month), then the thread and the chat box.
  await expect(page.locator("[data-test='agent-caption']")).toContainText("Turf");
  await expect(page.locator("[data-test='cto-chat-head'] [data-test='devops-stage']")).toHaveCount(3);
  await expect(page.locator("turbo-cable-stream-source[channel='CtoChatChannel']")).toHaveAttribute("connected", "");
  await expect(page.locator("[data-test='cto-chat-usage'] [data-test='usage-meter']")).toBeVisible();
  await expect(page.locator("[data-test='cto-chat-usage']")).toContainText("tokens this month");
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

  // The run's first pulse says thinking: Turf's portrait in the orbit, "Turf is
  // thinking", and the typing bubble drawn but hidden.
  const typing = await page.request.post(`/api/v1/agent_messages/${message.id}/typing`, { headers: auth, data: { worker, phase: "thinking" } });
  expect((await typing.json()).meta.typing).toBe("queued");
  const pulse = page.locator("#cto-chat-typing [data-test='cto-chat-typing']");
  await expect(pulse).toHaveAttribute("data-phase", "thinking");
  await expect(pulse.locator("[data-test='cto-chat-thinking']")).toBeVisible();
  await expect(pulse.locator("[data-test='cto-chat-thinking']")).toContainText("Turf is thinking");
  await expect(pulse.locator("[data-test='cto-chat-typing-bubble']")).toBeHidden();
  const thinkingBox = await page.locator("#cto-chat-typing").boundingBox();
  // The answer's words begin: the next pulse, in the same slot, says typing.
  const firstAt = await pulse.getAttribute("data-typing-at");
  const again = await page.request.post(`/api/v1/agent_messages/${message.id}/typing`, { headers: auth, data: { worker, phase: "typing" } });
  expect((await again.json()).meta.typing).toBe("queued");
  await expect(pulse).not.toHaveAttribute("data-typing-at", firstAt);
  await expect(pulse).toHaveAttribute("data-phase", "typing");
  await expect(pulse.locator("[data-test='cto-chat-typing-bubble']")).toBeVisible();
  await expect(pulse.locator("[data-test='cto-chat-typing-bubble']")).toContainText("Turf is typing");
  await expect(pulse.locator("[data-test='cto-chat-thinking']")).toBeHidden();
  const typingBox = await page.locator("#cto-chat-typing").boundingBox();
  expect(typingBox.height, "the swap does not move the page").toBe(thinkingBox.height);
  // A pulse from a dispatcher that sends no phase still reads as typing.
  const bare = await page.request.post(`/api/v1/agent_messages/${message.id}/typing`, { headers: auth, data: { worker } });
  expect((await bare.json()).meta.typing).toBe("queued");
  await expect(pulse).toHaveAttribute("data-phase", "typing");

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

test("an app's owner is answered on their own app's chat, as its client", async ({ page }) => {
  await loginWithMagicLink(page, "owner@cyvasse.test");
  await page.goto("/applications/cyvasse/chat");

  await expect(page.locator("[data-test='cto-chat-unanswered']")).toHaveCount(0);
  await expect(page.locator("[data-test='cto-chat-usage'] [data-test='usage-meter-line']")).toContainText("1,000,000");
  const input = page.locator("[data-test='cto-chat-input']");
  const text = `Hello Tyrion ${Date.now()}`;
  await input.fill(text);
  await page.locator("[data-test='cto-chat-send']").click();
  const turn = page.locator("[data-test='cto-chat-turn']", { hasText: text });
  await expect(turn).toHaveAttribute("data-status", "received");
  await expect(turn.locator("[data-test='cto-chat-held']")).toHaveCount(0);

  // Another app's chat does not exist for this owner.
  const other = await page.goto("/applications/mcritchie-studio/chat");
  expect(other.status()).toBe(404);
});

test("an app's owner says go on a proposal in their own chat and sees the designed task", async ({ page, browser }) => {
  const { pageErrors, report } = watchPageErrors(page);
  // e2e/seed.rb: owner@turf.test (a plain viewer, no agent role) has a pending
  // change proposal under an answered question on their own Turf chat.
  await loginWithMagicLink(page, "owner@turf.test");
  await page.goto("/applications/turf-monster/chat");

  const offer = page.locator("[data-test='cto-chat-turn']", { hasText: "Can the slate show kickoff times?" });
  await expect(offer.locator("[data-test='cto-chat-reply']")).toContainText("Proposed: Open a task to show kickoff times");
  await expect(page.locator("turbo-cable-stream-source[channel='CtoChatChannel']")).toHaveAttribute("connected", "");

  let slug = null;
  try {
    const input = page.locator("[data-test='cto-chat-input']");
    await input.fill("go");
    await input.press("Enter");
    const go = page.locator("[data-test='cto-chat-turn']").filter({ has: page.locator("[data-test='cto-chat-sent']", { hasText: /^go$/ }) }).last();
    await expect(go).toHaveCount(1);
    await expect(go.locator("[data-test='cto-chat-confirm-held']")).toHaveCount(0);

    // AgentProposalJob opens the task; its answer streams into the go's turn.
    const link = go.locator("[data-test='cto-chat-reply'] a[href*='/tasks/e2e-owner-kickoff-times']");
    await expect(link).toBeVisible({ timeout: 20_000 });
    await expect(go.locator("[data-test='cto-chat-reply']")).toContainText("Opened");
    slug = (await link.getAttribute("href")).split("/tasks/").pop();

    await page.reload();
    await expect(page.locator(`[data-test='cto-chat-reply'] a[href$='/tasks/${slug}']`)).toBeVisible();
    expect(pageErrors, report()).toHaveLength(0);
  } finally {
    // The task the go opened is this spec's row: delete it, so no later spec that
    // measures the board sees it.
    if (slug) {
      const admin = await browser.newContext({ storageState: ADMIN_STATE });
      const adminPage = await admin.newPage();
      const token = await apiToken(adminPage);
      await adminPage.request.delete(`/api/v1/tasks/${slug}`, { headers: { Authorization: `Bearer ${token}` } });
      await admin.close();
    }
  }
});
