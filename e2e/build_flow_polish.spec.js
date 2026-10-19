// [e2e] The /build chat's polish (task build-flow-polish).
//
//   1. Alex, 2026-10-19: "When the chat is within 20px of the bottom, new agent
//      text appearing should bump to the bottom so the user doesn't have to
//      scroll to keep up." A reader at the end stays there while an answer types
//      in letter by letter and while a new turn lands; a reader scrolled 200px up
//      is not moved (app/javascript/chat_follow.js).
//   2. Choose Theme on the theme already chosen posts nothing (no visitor turn,
//      no turn of Ray's); picking another theme enables it again.
//   3. The domain card makes no availability request of its own when it arrives
//      (the server's render already checked every name once); a changed name is
//      checked once.
// NOT @qa-readonly: it writes requests and agent messages.
const { test, expect } = require("@playwright/test");
const { blockThirdPartyRequests, loginWithMagicLink, watchPageErrors, VISITOR } = require("./helpers");

test.use({ storageState: VISITOR });

const PALETTE = {
  name: "Pitch",
  light: { primary: "#15803d", accent: "#f59e0b", surface: "#ffffff", text: "#111827" },
  dark: { primary: "#4ade80", accent: "#fbbf24", surface: "#0b1220", text: "#f1f5f9" },
};

// The mailbox API's bearer token, read from an admin page in a SEPARATE context,
// so the visitor's own browser stays signed out.
async function adminToken(browser) {
  const context = await browser.newContext();
  const admin = await context.newPage();
  await loginWithMagicLink(admin, "alex@test.com");
  await admin.goto("/agents/activities");
  const token = await admin.getAttribute("meta[name='e2e-api-token']", "content");
  await context.close();
  return token;
}

// Ray answers the visitor's message through the real mailbox API; the page polls.
async function rayAnswers(page, auth, content, text, card) {
  const worker = `e2e-polish-${Date.now()}`;
  for (let i = 0; i < 10; i += 1) {
    const claimed = await page.request.post("/api/v1/agent_messages/claim", { headers: auth, data: { souls: ["ray"], worker, channel: "web" } });
    expect(claimed.ok()).toBeTruthy();
    const message = (await claimed.json()).data;
    expect(message, `a ray message waiting for "${content}"`).toBeTruthy();
    const mine = message.content === content;
    const body = mine && card ? `${text}\n===PROPOSAL===\n${JSON.stringify({ kind: "intake", ...card })}` : (mine ? text : "ok");
    const done = await page.request.post(`/api/v1/agent_messages/${message.id}/complete`, { headers: auth, data: { worker, response_text: body } });
    expect(done.ok()).toBeTruthy();
    if (mine) return;
  }
  throw new Error(`never claimed "${content}"`);
}

// The visitor's first message on /build, past the bot shield's two seconds.
async function start(page, idea) {
  await page.goto("/build");
  const box = page.getByLabel("Tell Ray what you want to build");
  await box.fill(idea);
  await page.waitForTimeout(2200);
  await box.press("Enter");
  await expect(page.locator("[data-test='build-turn']", { hasText: idea })).toHaveAttribute("data-pending", "true");
}

async function send(page, text) {
  const input = page.locator("[data-test='cto-chat-input']");
  await input.fill(text);
  await input.press("Enter");
  await expect(page.locator("[data-test='build-turn']", { hasText: text })).toHaveAttribute("data-pending", "true");
}

// A long answer: enough lines that the thread scrolls and the reveal takes a while.
function longAnswer(label) {
  return Array.from({ length: 14 }, (_, i) => `${label} line ${i + 1}: ${"a few more words about the app ".repeat(3)}`).join("\n\n");
}

const log = "[data-cto-chat-scroll]";

// Samples the thread between frames while an answer types: how far from its end
// it sits, and where it is scrolled to.
async function startSampling(page) {
  await page.evaluate((selector) => {
    const samples = window.__follow = { distances: [], tops: [], typing: 0 };
    window.__followTimer = setInterval(() => {
      const el = document.querySelector(selector);
      if (!el) return;
      if (document.querySelector("[data-agent-revealing]")) samples.typing += 1;
      samples.distances.push(el.scrollHeight - el.clientHeight - el.scrollTop);
      samples.tops.push(el.scrollTop);
    }, 10);
  }, log);
}

async function stopSampling(page) {
  return page.evaluate(() => { clearInterval(window.__followTimer); return window.__follow; });
}

test("a reader at the end of the thread stays pinned as an answer types in and a turn lands; one scrolled up 200px is not moved", async ({ page, browser }) => {
  test.setTimeout(90_000);
  await blockThirdPartyRequests(page);
  const { pageErrors, report } = watchPageErrors(page);
  const auth = { Authorization: `Bearer ${await adminToken(browser)}`, "Content-Type": "application/json" };
  await page.setViewportSize({ width: 1280, height: 800 });
  const idea = `A tide chart for surfers ${Date.now()}`;
  await start(page, idea);
  // With motion, as a visitor sees it: the answers type themselves in.
  await page.emulateMedia({ reducedMotion: "no-preference" });

  // A first long answer makes the thread scroll.
  await rayAnswers(page, auth, idea, longAnswer("First"));
  await expect(page.locator("[data-agent-revealing]")).toHaveCount(0);
  const scrolls = await page.locator(log).evaluate((el) => el.scrollHeight > el.clientHeight + 200);
  expect(scrolls, "the thread is long enough to scroll").toBe(true);

  // 1. At the end (the reader's own send puts them there; then 12px up, inside
  //    the 20px): the next answer types in, and they are kept at its end.
  const second = `And a swell alert ${Date.now()}`;
  await send(page, second);
  await page.locator(log).evaluate((el) => { el.scrollTop = el.scrollHeight - el.clientHeight - 12; });
  await page.waitForTimeout(100);
  await startSampling(page);
  await rayAnswers(page, auth, second, longAnswer("Second"));
  await expect(page.locator("[data-test='build-turn']", { hasText: second }).locator("[data-agent-reveal]")).toContainText("Second line 14");
  await expect(page.locator("[data-agent-revealing]")).toHaveCount(0);
  await page.waitForTimeout(150);
  const pinned = await stopSampling(page);
  expect(pinned.typing, "sampled while the words typed").toBeGreaterThan(3);
  expect(Math.max(...pinned.distances.slice(-5)), "it ends at the end of the thread").toBeLessThanOrEqual(1);
  expect(Math.max(...pinned.distances), "never left more than 20px behind the words as they typed").toBeLessThanOrEqual(20);

  // 2. Scrolled 200px up, reading back: the next answer and its turn land below
  //    and the reader is not moved.
  const third = `What about wind ${Date.now()}`;
  await send(page, third);
  await page.waitForTimeout(100);
  const readingAt = await page.locator(log).evaluate((el) => { el.scrollTop = el.scrollHeight - el.clientHeight - 200; return el.scrollTop; });
  await page.waitForTimeout(100);
  await startSampling(page);
  await rayAnswers(page, auth, third, longAnswer("Third"));
  await expect(page.locator("[data-test='build-turn']", { hasText: third }).locator("[data-agent-reveal]")).toContainText("Third line 14");
  await expect(page.locator("[data-agent-revealing]")).toHaveCount(0);
  await page.waitForTimeout(150);
  const reading = await stopSampling(page);
  expect(reading.typing, "sampled while the words typed").toBeGreaterThan(3);
  expect(new Set(reading.tops), "the reader scrolled up stays exactly where they were").toEqual(new Set([readingAt]));
  expect(await page.locator(log).evaluate((el) => el.scrollHeight - el.clientHeight - el.scrollTop), "the new text is below them")
    .toBeGreaterThan(200);
  expect(pageErrors, report()).toHaveLength(0);
});

test("re-tapping the chosen theme posts nothing; another theme posts again", async ({ page, browser }) => {
  test.setTimeout(60_000);
  await blockThirdPartyRequests(page);
  const { pageErrors, report } = watchPageErrors(page);
  const auth = { Authorization: `Bearer ${await adminToken(browser)}`, "Content-Type": "application/json" };
  const idea = `A league site ${Date.now()}`;
  await start(page, idea);
  const themes = ["Pitch", "Field", "Court"].map((name) => ({ ...PALETTE, name }));
  await rayAnswers(page, auth, idea, "Pick a theme.", { card: "palette", palettes: themes });
  const themeCard = page.locator("[data-test='build-card-palette']");
  const choose = themeCard.getByRole("button", { name: "Choose Theme" });
  await expect(choose).toBeEnabled();
  await choose.click();
  const relay = page.locator("[data-test='build-turn']", { hasText: "Let's go with the Field theme." });
  await expect(relay).toHaveCount(1);
  await expect(themeCard.locator("[data-test='build-palette']").nth(1)).toHaveAttribute("data-chosen", "true");

  // Field is chosen and selected: Choose Theme is disabled, and even a forced
  // tap sends nothing.
  const posts = [];
  page.on("request", (request) => { if (request.method() !== "GET" && /\/build\/[^/]+\/intake$/.test(new URL(request.url()).pathname)) posts.push(request.url()); });
  await expect(choose).toBeDisabled();
  await choose.click({ force: true });
  await page.waitForTimeout(800);
  expect(posts, "the chosen theme posts nothing").toEqual([]);
  await expect(page.locator("[data-test='build-turn']", { hasText: "Let's go with the" })).toHaveCount(1);

  // Another theme enables it; back on the chosen one, it is disabled again.
  await themeCard.locator("[data-test='build-palette']").nth(0).click();
  await expect(choose).toBeEnabled();
  await themeCard.locator("[data-test='build-palette']").nth(1).click();
  await expect(choose).toBeDisabled();
  await themeCard.locator("[data-test='build-palette']").nth(2).click();
  await choose.click();
  await expect(page.locator("[data-test='build-turn']", { hasText: "Let's go with the Court theme." })).toHaveCount(1);
  expect(posts).toHaveLength(1);
  expect(pageErrors, report()).toHaveLength(0);
});

test("the domain card asks for availability once its name changes, never on arrival, and says its suffix to a screen reader", async ({ page, browser }) => {
  test.setTimeout(60_000);
  await blockThirdPartyRequests(page);
  const { pageErrors, report } = watchPageErrors(page);
  const auth = { Authorization: `Bearer ${await adminToken(browser)}`, "Content-Type": "application/json" };
  const idea = `A trivia night app ${Date.now()}`;
  const free = `quiz-${Date.now().toString(36)}`;
  await start(page, idea);
  const checks = [];
  page.on("request", (request) => { if (new URL(request.url()).pathname === "/build/check") checks.push(new URL(request.url()).search); });

  await rayAnswers(page, auth, idea, "Pick a domain.", { card: "address", names: ["trivia-night", free, `${free}-2`] });
  const card = page.locator("[data-test='build-card-address']");
  const field = card.locator("[data-test='build-address-input']");
  await expect(field).toHaveValue(free);
  await expect(card.locator("[data-test='build-address-availability']"), "the render brought its answer").toHaveText("Available");
  await expect(card.getByRole("button", { name: "Use Domain" })).toBeEnabled();
  await page.waitForTimeout(1200); // past the poll and the live check's 250ms debounce
  expect(checks, "the card asked nothing on arrival").toEqual([]);

  // The field's accessible description names the suffix it is drawn beside.
  const description = await field.evaluate((el) => el.getAttribute("aria-describedby").split(" ")
    .map((id) => document.getElementById(id)?.textContent.trim()).join(" "));
  expect(description).toContain("Ends in .mcritchie.studio.");

  // A chip tap changes the name: one check, for that name.
  await card.locator("[data-test='build-address-suggestion']", { hasText: `${free}-2` }).click();
  await expect(card.locator("[data-test='build-address-availability']")).toHaveText("Available");
  await page.waitForTimeout(500);
  expect(checks).toEqual([`?subdomain=${free}-2`]);
  expect(pageErrors, report()).toHaveLength(0);
});
