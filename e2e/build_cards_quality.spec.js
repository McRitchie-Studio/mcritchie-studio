// [e2e] The /build cards' quality pass (task build-cards-quality-pass; Alex McRitchie,
// 2026-10-19, from production screenshots).
//
//   1. The status card pops (grows past full size with a glow) when Start App first draws it, and its three tiles
//      read Theme, Agent, Domain (never "Not yet"), the theme step marked as the
//      one in progress.
//   2. The theme card's Dark / Light control is a toggle: a second tap on the
//      side already showing flips it.
//   3. Choose Theme's moving orbit glow turns inside its own ring: on a 375px
//      phone neither the page nor the chat thread scrolls sideways while it runs.
//   4. Pick three new themes sends "Can you give me three new theme ideas?" as
//      the visitor's own chat turn, and a draft already in the box survives it.
// NOT @qa-readonly: it writes requests and agent messages.
const { test, expect } = require("@playwright/test");
const { blockThirdPartyRequests, loginWithMagicLink, watchPageErrors, VISITOR } = require("./helpers");

test.use({ storageState: VISITOR });

const PALETTE = {
  name: "Pitch",
  light: { primary: "#15803d", accent: "#f59e0b", surface: "#ffffff", text: "#111827" },
  dark: { primary: "#4ade80", accent: "#fbbf24", surface: "#0b1220", text: "#f1f5f9" },
};

async function adminToken(browser) {
  const context = await browser.newContext();
  const admin = await context.newPage();
  await loginWithMagicLink(admin, "alex@test.com");
  await admin.goto("/agents/activities");
  const token = await admin.getAttribute("meta[name='e2e-api-token']", "content");
  await context.close();
  return token;
}

// Alex answers the first waiting message whose content passes `matches`, through
// the real mailbox API; the page polls. Any other message gets a plain "ok".
async function rayAnswers(page, auth, matches, text, card) {
  const worker = `e2e-cards-${Date.now()}`;
  for (let i = 0; i < 10; i += 1) {
    const claimed = await page.request.post("/api/v1/agent_messages/claim", { headers: auth, data: { souls: ["alex"], worker, channel: "web" } });
    expect(claimed.ok()).toBeTruthy();
    const message = (await claimed.json()).data;
    expect(message, "a alex message waiting").toBeTruthy();
    const mine = matches(message.content);
    const body = mine && card ? `${text}\n===PROPOSAL===\n${JSON.stringify({ kind: "intake", ...card })}` : (mine ? text : "ok");
    const done = await page.request.post(`/api/v1/agent_messages/${message.id}/complete`, { headers: auth, data: { worker, response_text: body } });
    expect(done.ok()).toBeTruthy();
    if (mine) return message.content;
  }
  throw new Error("never claimed the message");
}

async function start(page, idea) {
  await page.setExtraHTTPHeaders({ "X-Forwarded-For": `198.51.100.${1 + Math.floor(Math.random() * 250)}` });
  await page.goto("/build");
  const box = page.getByLabel("Tell Alex what you want to build");
  await box.fill(idea);
  await page.waitForTimeout(2200);
  await box.press("Enter");
  await expect(page.locator("[data-test='build-turn']", { hasText: idea })).toHaveAttribute("data-pending", "true");
}

// No sideways scroll on the page or in the chat thread.
async function sidewaysOverflow(page) {
  return page.evaluate(() => {
    const doc = document.scrollingElement;
    const log = document.querySelector("[data-cto-chat-scroll]");
    return { page: doc.scrollWidth - doc.clientWidth, thread: log ? log.scrollWidth - log.clientWidth : 0 };
  });
}

test("the theme card pops a status card of Theme, Agent, Domain; the theme card toggles, glows in its ring at 375px, and asks Alex for new themes", async ({ page, browser }) => {
  test.setTimeout(90_000);
  await blockThirdPartyRequests(page);
  const { pageErrors, report } = watchPageErrors(page);
  const auth = { Authorization: `Bearer ${await adminToken(browser)}`, "Content-Type": "application/json" };
  await page.setViewportSize({ width: 375, height: 800 });
  const idea = `A weekly trivia night with friends ${Date.now()}`;
  await start(page, idea);
  await rayAnswers(page, auth, (c) => c === idea, "Here's the app.",
                   { card: "idea", title: "Weekly Trivia With Friends", features: ["Rounds", "Scores"] });

  // 1. Start App locks the idea, but the status card waits for Alex's theme card
  //    (task status-card-waits-theme); it arrives with that card and pops
  //    (agent_shell.js's enter animation, which plays only with motion); the
  //    tiles name their steps.
  await page.emulateMedia({ reducedMotion: "no-preference" });
  await page.evaluate(() => {
    window.__popped = null;
    new MutationObserver(() => {
      const card = document.querySelector("[data-build-status-card].agent-shell-enter-card");
      if (card && !window.__popped) window.__popped = getComputedStyle(card).animationName;
    }).observe(document.body, { subtree: true, childList: true, attributes: true, attributeFilter: ["class"] });
  });
  await page.getByRole("button", { name: "Start App" }).click();
  const status = page.locator("[data-test='build-status-card']");
  await expect(page.locator("#build-checklist[data-heading='locked'] [data-test='build-heading-title']")).toHaveText("Weekly Trivia With Friends");
  await expect(status).toHaveCount(0);

  // The Start App relay brings Alex's theme card, and the status card with it.
  const themes = ["Pitch", "Field", "Court"].map((name) => ({ ...PALETTE, name }));
  await rayAnswers(page, auth, (c) => c.startsWith("Let's build"), "Pick a theme.", { card: "palette", palettes: themes });
  const themeCard = page.locator("[data-test='build-card-palette']");
  await expect(themeCard).toBeVisible();
  await expect(status).toBeVisible();
  await expect.poll(() => page.evaluate(() => window.__popped), { message: "the card popped when it arrived with the theme card" }).toBe("agent-shell-pop-in");
  await expect(status.locator("[data-test='build-tile-theme-value']")).toContainText("Theme");
  await expect(status.locator("[data-test='build-tile-agent-value']")).toHaveText("Agent");
  await expect(status.locator("[data-test='build-tile-domain-value']")).toHaveText("Domain");
  await expect(status).not.toContainText("Not yet");
  await expect(status.locator("[data-test='build-tile-theme']")).toHaveAttribute("data-current", "true");

  // 2. The toggle: dark first; Light shows light; a second tap on Light flips
  //    back to dark; a tap on Dark while dark shows light.
  const dark = themeCard.locator("[data-test='build-theme-toggle-dark']");
  const light = themeCard.locator("[data-test='build-theme-toggle-light']");
  const preview = (mode) => themeCard.locator(`[data-build-theme-preview='${mode}']`).first();
  await expect(dark).toHaveAttribute("aria-pressed", "true");
  await light.click();
  await expect(light).toHaveAttribute("aria-pressed", "true");
  await expect(preview("light")).toBeVisible();
  await light.click();
  await expect(dark).toHaveAttribute("aria-pressed", "true", { timeout: 2000 });
  await expect(preview("dark")).toBeVisible();
  await dark.click();
  await expect(light).toHaveAttribute("aria-pressed", "true");
  await expect(preview("light")).toBeVisible();

  // 3. With motion, the orbit ring turns behind Choose Theme, and nothing on the
  //    375px page, nor in the thread, scrolls sideways at any point of its turn.
  const choose = themeCard.getByRole("button", { name: "Choose Theme" });
  await choose.scrollIntoViewIfNeeded();
  const ring = themeCard.locator("[data-test='build-palette-glow-ring']");
  await expect(ring).toBeVisible();
  expect(await ring.evaluate((el) => getComputedStyle(el, "::before").animationName)).toBe("cta-glow-orbit");
  expect(await ring.evaluate((el) => getComputedStyle(el).overflow)).toBe("hidden");
  for (let i = 0; i < 8; i += 1) {
    expect(await sidewaysOverflow(page), `no sideways scroll, sample ${i}`).toEqual({ page: 0, thread: 0 });
    await page.waitForTimeout(500);
  }

  // 4. Pick three new themes: the visitor's own turn, sent through the chat box.
  //    A half-typed draft rides out the send and is back in the box after it
  //    (task client-flow-review-leftovers).
  const box = page.locator("[data-test='cto-chat-input']");
  await box.fill("make it feel like a lake cabin");
  await themeCard.getByRole("button", { name: "Pick three new themes" }).click();
  await expect(page.locator("[data-test='build-turn']", { hasText: "Can you give me three new theme ideas?" })).toHaveAttribute("data-pending", "true");
  await expect(box, "the draft is back in the redrawn box").toHaveValue("make it feel like a lake cabin");
  await expect(page.locator("[data-test='build-turn']", { hasText: "make it feel like a lake cabin" })).toHaveCount(0);
  expect(pageErrors, report()).toHaveLength(0);
});
