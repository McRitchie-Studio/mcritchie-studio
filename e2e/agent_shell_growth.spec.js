// [e2e] The agent shell as the conversation grows (app/views/agent_chats/_shell.html.erb,
// app/javascript/agent_shell.js, app/assets/tailwind/agent_shell.css; tasks
// build-launch-chat-growth and build-chat-reading-flow). Alex, 2026-10-18: the
// conversation should take about 40% of the window at first and about 80% as it goes
// on, the chat box always at the window's bottom; and the head's makeup (the gallery
// gone, "Want to Build Something?" shrunk) should follow the CHAT'S SIZE as it
// grows, not the send of a message. A new answer from Ritch types itself in, and his
// words sit on the page, not in a bubble (app/javascript/agent_reveal.js).
//
// What only a browser shows: the first message animates in place (no reload) and
// leaves the hero and gallery standing; the head compacts in steps as the thread
// grows, and the gallery slides away; the shell stops at the window's height while
// the thread scrolls inside it; the chat box stays in the window; a reload opens at
// its thread's step. Then the same on the CTO chat, and the typewriter.
// NOT @qa-readonly: it writes requests and agent messages.
const { test, expect } = require("@playwright/test");
const { blockThirdPartyRequests, loginWithMagicLink, watchPageErrors, VISITOR } = require("./helpers");

test.use({ storageState: VISITOR });

// The mailbox API's bearer token, read from an admin page in a SEPARATE context,
// so the visitor's own browser stays signed out (as build_funnel.spec.js does).
async function adminToken(browser) {
  const context = await browser.newContext();
  const admin = await context.newPage();
  await loginWithMagicLink(admin, "alex@test.com");
  await admin.goto("/agents/activities");
  const token = await admin.getAttribute("meta[name='e2e-api-token']", "content");
  await context.close();
  return token;
}

// Ritch answers the visitor's message through the real mailbox API; the page polls.
async function rayAnswers(page, auth, content, body) {
  const worker = `e2e-reveal-${Date.now()}`;
  for (let i = 0; i < 10; i += 1) {
    const claimed = await page.request.post("/api/v1/agent_messages/claim", { headers: auth, data: { souls: ["ray"], worker, channel: "web" } });
    expect(claimed.ok()).toBeTruthy();
    const message = (await claimed.json()).data;
    expect(message, `a ray message waiting for "${content}"`).toBeTruthy();
    const mine = message.content === content;
    const done = await page.request.post(`/api/v1/agent_messages/${message.id}/complete`, { headers: auth, data: { worker, response_text: mine ? body : "ok" } });
    expect(done.ok()).toBeTruthy();
    if (mine) return;
  }
  throw new Error(`never claimed "${content}"`);
}

// The shell's height as a share of the window, the head's height, and whether the
// chat box sits inside the window.
async function measure(page) {
  return page.evaluate(() => {
    const shell = document.querySelector("[data-agent-shell]");
    const form = shell.querySelector("[data-cto-chat-form], [data-build-first-form]");
    const log = shell.querySelector("[data-cto-chat-scroll]");
    const head = shell.querySelector("[data-test='agent-shell-head']").getBoundingClientRect();
    const box = form.getBoundingClientRect();
    return {
      size: shell.dataset.shellSize,
      share: shell.getBoundingClientRect().height / window.innerHeight,
      head: head.height,
      composerInView: box.top >= 0 && box.bottom <= window.innerHeight + 1,
      // The thread ends where the chat box starts: nothing hides behind the box.
      threadClear: log ? log.getBoundingClientRect().bottom <= box.top + 1 : true,
      shellBottom: shell.getBoundingClientRect().bottom - window.innerHeight,
      logScrolls: log ? log.scrollHeight > log.clientHeight + 4 : false,
      logAtEnd: log ? log.scrollHeight - log.clientHeight - log.scrollTop <= 2 : true,
    };
  });
}

async function send(page, text) {
  const input = page.locator("[data-test='cto-chat-input']");
  await input.fill(text);
  await input.press("Enter");
  await expect(page.locator("[data-test='cto-chat-sent']", { hasText: text })).toHaveCount(1);
}

test("on /build the first message leaves the hero standing; the head compacts as the thread grows, and a long conversation keeps the chat box in view", async ({ page }) => {
  await blockThirdPartyRequests(page);
  const { pageErrors, report } = watchPageErrors(page);
  await page.setViewportSize({ width: 1280, height: 800 });
  await page.goto("/build");
  // With motion, as a visitor sees it (the suite runs reduced).
  await page.emulateMedia({ reducedMotion: "no-preference" });

  const start = await measure(page);
  expect(start.size).toBe("full");
  expect(start.share, "the opening shell is under half the window").toBeLessThan(0.62);
  const gallery = page.locator("[data-test='build-gallery']");
  await expect(gallery, "the gallery shows below the opening shell").toBeInViewport({ ratio: 0.2 });
  const fullHead = start.head;

  await page.evaluate(() => {
    window.__marker = "kept";
    window.__animated = [];
    window.__sizes = [];
    document.addEventListener("animationstart", (e) => window.__animated.push(e.animationName));
    document.addEventListener("transitionstart", (e) => window.__animated.push(`${e.target.className.split?.(" ")[0] || e.target.tagName}:${e.propertyName}`));
    new MutationObserver(() => {
      const size = document.querySelector("[data-agent-shell]")?.dataset.shellSize;
      if (size && window.__sizes.at(-1) !== size) window.__sizes.push(size);
    }).observe(document.body, { subtree: true, attributes: true, attributeFilter: ["data-shell-size"] });
  });
  const box = page.getByLabel("Tell Ritch what you want to build");
  await box.fill(`A recipe box for my family ${Date.now()}`);
  await page.waitForTimeout(2200); // past the bot shield's two seconds
  await box.press("Enter");
  await expect(page).toHaveURL(/\/build\/[A-Za-z0-9_-]{10,}$/);
  expect(await page.evaluate(() => window.__marker), "no reload").toBe("kept");
  // The thread slides in; a SEND does not compact the head: one short turn still
  // fits beside the hero, so the heading, the subtitle and the gallery stay.
  await expect.poll(() => page.evaluate(() => window.__animated.includes("agent-shell-thread-in"))).toBe(true);
  await page.waitForTimeout(600);
  await expect(page.locator("[data-agent-shell]")).toHaveAttribute("data-shell-size", "full");
  await expect(page.locator("[data-test='build-heading'] .agent-shell-subtitle")).toBeVisible();
  await expect(gallery, "the gallery stays while the conversation is short").toBeVisible();
  expect((await measure(page)).head, "the hero kept its size").toBeGreaterThanOrEqual(fullHead - 1);

  // As the thread grows the head steps down (medium, then compact, one way), its
  // shrink animated, and the gallery slides away for good.
  for (let i = 1; i <= 7; i += 1) {
    await send(page, `Another thought, number ${i}: ${"and some detail ".repeat(6)}`);
  }
  await expect(page.locator("[data-agent-shell]")).toHaveAttribute("data-shell-size", "compact");
  await expect(gallery, "the gallery went once the thread grew").toBeHidden();
  expect(await page.evaluate(() => window.__sizes), "full, then medium, then compact: forward only").toEqual(["medium", "compact"]);
  await expect.poll(() => page.evaluate(() => {
    const seen = window.__animated;
    return {
      portrait: seen.some((name) => name.endsWith(":width")),
      subtitle: seen.some((name) => /^agent-shell-subtitle:/.test(name)),
      heading: seen.some((name) => /^text-3xl:font-size$/.test(name)),
      gallery: seen.some((name) => /:opacity$/.test(name) && !/^agent-shell-subtitle/.test(name)),
    };
  })).toEqual({ portrait: true, subtitle: true, heading: true, gallery: true });
  await page.waitForTimeout(500);
  const grown = await measure(page);
  expect(grown.share, "the conversation fills most of the window").toBeGreaterThan(0.75);
  expect(grown.share, "never taller than the window").toBeLessThanOrEqual(1.0);
  expect(grown.logScrolls, "the thread scrolls inside the shell").toBe(true);
  expect(grown.logAtEnd, "at its newest turn").toBe(true);
  expect(grown.composerInView, "the chat box is in the window").toBe(true);
  expect(grown.threadClear, "no turn hides behind the chat box").toBe(true);
  expect(grown.shellBottom, "the shell ends at the window's bottom").toBeLessThanOrEqual(1);
  expect(grown.head, "the head is one compact line").toBeLessThan(56);
  await expect(page.locator("[data-test='build-heading'] h1")).toHaveCSS("font-size", "20px");

  // A phone: the same promises.
  await page.setViewportSize({ width: 390, height: 744 });
  await page.waitForTimeout(100);
  const phone = await measure(page);
  expect(phone.composerInView, "the chat box is in a phone's window").toBe(true);
  expect(phone.threadClear).toBe(true);
  expect(phone.share).toBeLessThanOrEqual(1.0);
  expect(await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth), "nothing runs off the side").toBeLessThanOrEqual(0);

  // A reload opens at its thread's step: compact, the gallery gone, at the end.
  await page.reload();
  await expect(page.locator("[data-agent-shell]")).toHaveAttribute("data-shell-size", "compact");
  await expect(gallery).toBeHidden();
  expect((await measure(page)).composerInView).toBe(true);
  expect(pageErrors, report()).toHaveLength(0);
});

test("the CTO chat grows the same way: compact head, window-tall thread, chat box in view", async ({ page }) => {
  const { pageErrors, report } = watchPageErrors(page);
  await loginWithMagicLink(page, "owner@cyvasse.test");
  await page.setViewportSize({ width: 1280, height: 800 });
  await page.goto("/applications/cyvasse/chat");
  await expect(page.locator("[data-agent-shell][data-shell='app']")).toBeVisible();
  for (let i = 1; i <= 6; i += 1) {
    await send(page, `Growth check ${Date.now()} ${i}: ${"a longer line of text ".repeat(5)}`);
  }
  await expect(page.locator("[data-agent-shell]")).toHaveAttribute("data-shell-size", "compact");
  await page.waitForTimeout(300);
  const grown = await measure(page);
  expect(grown.share).toBeGreaterThan(0.75);
  expect(grown.share).toBeLessThanOrEqual(1.0);
  expect(grown.composerInView).toBe(true);
  expect(grown.threadClear).toBe(true);
  expect(grown.shellBottom).toBeLessThanOrEqual(1);
  expect(grown.logAtEnd).toBe(true);
  expect(pageErrors, report()).toHaveLength(0);
});

test("a new answer from Ritch types itself in on the page, its card after it; history and a reload show at once", async ({ page, browser }) => {
  await blockThirdPartyRequests(page);
  const { pageErrors, report } = watchPageErrors(page);
  const auth = { Authorization: `Bearer ${await adminToken(browser)}`, "Content-Type": "application/json" };
  await page.setViewportSize({ width: 1280, height: 800 });
  await page.goto("/build");
  await page.emulateMedia({ reducedMotion: "no-preference" });
  const idea = `A tide chart for surfers ${Date.now()}`;
  const box = page.getByLabel("Tell Ritch what you want to build");
  await box.fill(idea);
  await page.waitForTimeout(2200);
  await box.press("Enter");
  const turn = page.locator("[data-test='build-turn']", { hasText: idea });
  await expect(turn).toHaveAttribute("data-pending", "true");

  // What the reveal does, as it does it: the live region busy (a screen reader
  // hears the answer once, when it is done), the typing words inert (no link in
  // them takes focus), the turn marked while it types, the card held back, the
  // visible words growing.
  await page.evaluate(() => {
    const seen = window.__reveal = { revealing: false, busy: false, inertBody: false, cardShownWhileTyping: false, lengths: [] };
    new MutationObserver(() => {
      const t = document.querySelector("[data-agent-revealing]");
      if (t) {
        seen.revealing = true;
        if (t.closest("[role='log']")?.getAttribute("aria-busy") === "true") seen.busy = true;
        const body = t.querySelector("[data-agent-reveal]");
        if (body?.inert) seen.inertBody = true;
        if (body) seen.lengths.push(body.textContent.length);
        const card = t.querySelector("[data-action-card]");
        if (card && card.getBoundingClientRect().height > 0) seen.cardShownWhileTyping = true;
      }
    }).observe(document.body, { subtree: true, childList: true, characterData: true, attributes: true });
  });

  const words = "Here is the app **I hear**: a tide chart that knows your break.\n\n- Tides by the hour\n- Swell and wind together\n- A morning alert when it is good";
  const card = { kind: "intake", card: "idea", title: "Tide Chart", features: ["Tides", "Swell"] };
  await rayAnswers(page, auth, idea, `${words}\n===PROPOSAL===\n${JSON.stringify(card)}`);

  const reply = turn.locator("[data-test='cto-chat-reply']");
  await expect(reply.locator("[data-agent-reveal]")).toContainText("A morning alert when it is good");
  await expect(turn).not.toHaveAttribute("data-agent-revealing", "");
  await expect(turn.locator("[data-test='build-card-idea']"), "the card follows the words").toBeVisible();
  await expect(reply.locator("strong")).toHaveText("I hear");
  await expect(reply.locator("li")).toHaveCount(3);
  await expect(page.locator("[role='log'][aria-busy]"), "the live region is let go: the reader hears the finished answer").toHaveCount(0);
  expect(await reply.locator("[data-agent-reveal]").evaluate((el) => el.inert), "the finished words take focus again").toBe(false);
  await expect(reply.locator("[data-agent-reveal-copy]"), "no second copy for a screen reader to read twice").toHaveCount(0);

  const seen = await page.evaluate(() => window.__reveal);
  expect(seen.revealing, "the answer typed in").toBe(true);
  expect(seen.busy, "the live region was busy while the words typed").toBe(true);
  expect(seen.inertBody, "the typing words were inert").toBe(true);
  expect(seen.cardShownWhileTyping, "the card waited for the words").toBe(false);
  expect(seen.lengths.length, "the words grew over several frames").toBeGreaterThan(3);
  expect(Math.min(...seen.lengths), "it started short").toBeLessThan(40);

  // Ritch's words sit on the page: no bubble behind them, in either theme.
  const look = await reply.evaluate((el) => {
    const style = getComputedStyle(el);
    return { bg: style.backgroundColor, border: style.borderTopWidth, width: el.getBoundingClientRect().width,
             log: el.closest("[data-cto-chat-scroll]").getBoundingClientRect().width };
  });
  expect(look.bg).toBe("rgba(0, 0, 0, 0)");
  expect(look.border).toBe("0px");
  expect(look.width, "the thread's full width").toBeGreaterThan(look.log * 0.9);
  const cardLook = await turn.locator("[data-test='build-card-idea']").evaluate((el) => getComputedStyle(el).borderTopWidth);
  expect(cardLook, "the card keeps its bubble").not.toBe("0px");

  // A reload is history: the answer is there at once, never typed again.
  await page.reload();
  await page.evaluate(() => {
    window.__typedAgain = false;
    new MutationObserver(() => { if (document.querySelector("[data-agent-revealing]")) window.__typedAgain = true; })
      .observe(document.body, { subtree: true, attributes: true });
  });
  const again = page.locator("[data-test='build-turn']", { hasText: idea }).locator("[data-test='cto-chat-reply'] [data-agent-reveal]");
  await expect(again).toContainText("A morning alert when it is good");
  await expect(page.locator("[data-agent-revealing]")).toHaveCount(0);
  await page.waitForTimeout(800);
  expect(await page.evaluate(() => window.__typedAgain)).toBe(false);
  expect(pageErrors, report()).toHaveLength(0);
});
