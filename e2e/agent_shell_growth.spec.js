// [e2e] The agent shell as the conversation grows (app/views/agent_chats/_shell.html.erb,
// app/javascript/agent_shell.js, app/assets/tailwind/agent_shell.css; task
// build-launch-chat-growth). Alex, 2026-10-18: the conversation should take about 40%
// of the window at first and about 80% as it goes on, the chat box always at the
// window's bottom, the gallery pushed off screen, and the move from /build to
// /build/<token> visibly animated.
//
// What only a browser shows: the first message animates in place (no reload), the
// head compacts in steps, the shell stops at the window's height while the thread
// scrolls inside it, and the chat box stays in the window. Then the same on the
// CTO chat. NOT @qa-readonly: it writes requests and agent messages.
const { test, expect } = require("@playwright/test");
const { blockThirdPartyRequests, loginWithMagicLink, watchPageErrors, VISITOR } = require("./helpers");

test.use({ storageState: VISITOR });

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

test("on /build the first message animates in place, and a long conversation keeps the chat box in view with the head compact", async ({ page }) => {
  await blockThirdPartyRequests(page);
  const { pageErrors, report } = watchPageErrors(page);
  await page.setViewportSize({ width: 1280, height: 800 });
  await page.goto("/build");
  // With motion, as a visitor sees it (the suite runs reduced).
  await page.emulateMedia({ reducedMotion: "no-preference" });

  const start = await measure(page);
  expect(start.size).toBe("full");
  expect(start.share, "the opening shell is under half the window").toBeLessThan(0.62);
  await expect(page.locator("[data-test='build-gallery']"), "the gallery shows below the opening shell").toBeInViewport({ ratio: 0.2 });
  const fullHead = start.head;

  await page.evaluate(() => {
    window.__marker = "kept";
    window.__animated = [];
    document.addEventListener("animationstart", (e) => window.__animated.push(e.animationName));
    document.addEventListener("transitionstart", (e) => window.__animated.push(`${e.target.className.split?.(" ")[0] || e.target.tagName}:${e.propertyName}`));
  });
  const box = page.getByLabel("Tell Ray what you want to build");
  await box.fill(`A recipe box for my family ${Date.now()}`);
  await page.waitForTimeout(2200); // past the bot shield's two seconds
  await box.press("Enter");
  await expect(page).toHaveURL(/\/build\/[A-Za-z0-9_-]{10,}$/);
  await expect(page.locator("[data-agent-shell]")).toHaveAttribute("data-shell-size", "medium");
  expect(await page.evaluate(() => window.__marker), "no reload").toBe("kept");
  // The move is animated: the thread slides in, the portrait and heading shrink.
  // (the gallery slides away too, before the stream removes it).
  await expect.poll(() => page.evaluate(() => {
    const seen = window.__animated;
    return {
      thread: seen.includes("agent-shell-thread-in"),
      portrait: seen.some((name) => name.endsWith(":width")),
      subtitle: seen.some((name) => /^agent-shell-subtitle:/.test(name)),
      heading: seen.some((name) => /^text-3xl:font-size$/.test(name)),
      gallery: seen.some((name) => /:opacity$/.test(name) && !/^agent-shell-subtitle/.test(name)),
    };
  })).toEqual({ thread: true, portrait: true, subtitle: true, heading: true, gallery: true });
  await page.waitForTimeout(500);
  expect((await measure(page)).head, "the portrait shrank").toBeLessThan(fullHead);

  // A long conversation: the head goes compact, the shell stops at the window, the
  // thread scrolls inside it, and the chat box stays in the window.
  for (let i = 1; i <= 7; i += 1) {
    await send(page, `Another thought, number ${i}: ${"and some detail ".repeat(6)}`);
  }
  await expect(page.locator("[data-agent-shell]")).toHaveAttribute("data-shell-size", "compact");
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

  // A reload paints compact at once (the server's step), with the thread at its end.
  await page.reload();
  await expect(page.locator("[data-agent-shell]")).toHaveAttribute("data-shell-size", "compact");
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
