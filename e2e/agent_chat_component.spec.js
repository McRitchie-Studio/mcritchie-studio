// [e2e] The shared agent chat's script (app/javascript/agent_chat.js), on its first
// page, the CTO chat. e2e/cto_web_chat.spec.js covers the live loop; this one pins
// what the module itself does in a browser: Shift+Enter is a new line and sends
// nothing, Enter sends, the fresh composer keeps focus, the log sits at its newest
// turn, and the old "cto_chat" import still resolves to the same module.
//
// NOT @qa-readonly: it writes agent messages (Cyvasse's owner, answered by the
// app-owner rule; their rows wait for tyrion, which no spec claims).
const fs = require("fs");
const path = require("path");
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink, watchPageErrors, VISITOR } = require("./helpers");

test.use({ storageState: VISITOR });

const PNG = { name: "probe.png", mimeType: "image/png",
  buffer: fs.readFileSync(path.join(__dirname, "..", "test", "fixtures", "files", "chat", "probe.png")) };

// Holds each chat POST's answer (after the server has stored the turn) until the
// test lets it go. `posts` counts the sends that reached the network.
async function holdSends(page) {
  const gates = [];
  await page.route("**/applications/cyvasse/chat", async (route) => {
    if (route.request().method() !== "POST") return route.continue();
    let release;
    const gate = new Promise((resolve) => { release = resolve; });
    gates.push(release);
    const response = await route.fetch();
    await gate;
    await route.fulfill({ response }).catch(() => {}); // an aborted submission has no one to answer
  });
  return { get posts() { return gates.length; }, releaseAll: () => gates.forEach((release) => release()) };
}

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

// Task shell-growth-spec-stops-flaking. The CTO chat shows a sent turn TWICE over:
// the turn's ActionCable broadcast (AgentMessages::WebChat.broadcast_turn) and the
// POST's own answer, which also replaces the composer with a fresh client id. The
// broadcast can land first, so for a moment the owner sees their message while the
// composer still holds the OLD form. A second message sent then rode the first's
// client id, and AgentMessages::WebIngest stored it as a double submit of the first:
// it vanished (e2e/agent_shell_growth.spec.js flaked on exactly this, in CI). And a
// draft typed in that moment was wiped when the late replace landed. The race is made
// certain here by holding the POST's answer after the server has stored the message.
test("a message sent before the last send's answer lands is kept, and so is a draft typed meanwhile", async ({ page }) => {
  const { pageErrors, report } = watchPageErrors(page);
  await loginWithMagicLink(page, "owner@cyvasse.test");
  await page.goto("/applications/cyvasse/chat");

  const held = [];
  await page.route("**/applications/cyvasse/chat", async (route) => {
    if (route.request().method() !== "POST") return route.continue();
    const response = await route.fetch(); // the server has stored and broadcast the turn
    held.push(response);
    await new Promise((resolve) => setTimeout(resolve, 1500));
    await route.fulfill({ response }).catch(() => {}); // an aborted submission has no one to answer
  });

  const input = page.locator("[data-test='cto-chat-input']");
  const sent = (text) => page.locator("[data-test='cto-chat-sent']", { hasText: text });
  const stamp = Date.now();
  const first = `First of two ${stamp}`;
  const second = `Second of two ${stamp}`;

  await input.fill(first);
  await input.press("Enter");
  await expect(sent(first), "the broadcast shows the turn while the answer is held").toHaveCount(1);
  expect(held.length, "the answer is still held").toBe(1);

  await input.fill(second);
  await input.press("Enter");
  await expect(sent(second), "the second message is its own turn, not a double submit of the first").toHaveCount(1);
  await expect(sent(first)).toHaveCount(1);

  // A draft typed while the second send posts survives its answer's composer swap.
  const draft = `A thought still being typed ${stamp}`;
  await input.fill(draft);
  await page.waitForTimeout(2000); // past the held answer
  await expect(page.locator("[data-test='cto-chat-input']")).toHaveValue(draft);
  await expect(sent(draft), "a draft is not sent").toHaveCount(0);

  expect(pageErrors, report()).toEqual([]);
});

// Task composer-edge-cases. A files-only message sent while a send posts is a
// message, not a repeated tap: it posts. Its send aborts the one before (Turbo
// runs one form submission at a time), and that earlier send's end lands while
// this one still posts: the composer stays aria-busy until the LAST settles.
test("a files-only send while one posts is sent, and the composer stays busy until the last send settles", async ({ page }) => {
  const { pageErrors, report } = watchPageErrors(page);
  await loginWithMagicLink(page, "owner@cyvasse.test");
  await page.goto("/applications/cyvasse/chat");
  const held = await holdSends(page);

  const form = page.locator("[data-test='cto-chat-form']");
  const input = page.locator("[data-test='cto-chat-input']");
  const first = `Before the picture ${Date.now()}`;
  await input.fill(first);
  await input.press("Enter");
  await expect.poll(() => held.posts).toBe(1);
  await expect(form).toHaveAttribute("aria-busy", "true");

  await page.locator("[data-test='cto-chat-file-input']").setInputFiles(PNG);
  await expect(page.locator("[data-test='cto-chat-chip'][data-state='done']")).toHaveCount(1);
  await input.press("Enter"); // no text: the file is the message
  await expect.poll(() => held.posts, { message: "the files-only send reached the server" }).toBe(2);

  await page.waitForTimeout(500); // the aborted first send's end has landed by now
  await expect(form, "the second send still posts").toHaveAttribute("aria-busy", "true");

  held.releaseAll();
  const picture = page.locator("[data-test='cto-chat-sent-file']");
  await expect(picture, "the files-only turn is in the log").toHaveCount(1);
  await expect(page.locator("[data-test='cto-chat-form']")).not.toHaveAttribute("aria-busy");
  await expect(page.locator("[data-test='cto-chat-chip']"), "a sent file does not come back").toHaveCount(0);

  expect(pageErrors, report()).toEqual([]);
});

// Task composer-edge-cases. A file attached while a send posts belongs to the NEXT
// message: the send's answer redraws the composer, and the file (and the caret)
// is carried into the new one, not wiped.
test("a file attached while a send posts survives the composer swap, and the caret stays in the box", async ({ page }) => {
  const { pageErrors, report } = watchPageErrors(page);
  await loginWithMagicLink(page, "owner@cyvasse.test");
  await page.goto("/applications/cyvasse/chat");
  const held = await holdSends(page);

  const input = page.locator("[data-test='cto-chat-input']");
  const stamp = Date.now();
  const first = `While this posts ${stamp}`;
  await input.fill(first);
  await input.press("Enter");
  await expect.poll(() => held.posts).toBe(1);

  await page.locator("[data-test='cto-chat-file-input']").setInputFiles(PNG);
  await expect(page.locator("[data-test='cto-chat-chip'][data-state='done']")).toHaveCount(1);
  const draft = `About this picture ${stamp}`;
  await input.fill(draft);
  await input.focus();
  const before = await page.locator("[data-test='cto-chat-form'] [data-test='cto-chat-input']").elementHandle();

  held.releaseAll();
  await expect.poll(() => before.evaluate((el) => el.isConnected), { message: "the answer redrew the composer" }).toBe(false);
  await expect(page.locator("[data-test='cto-chat-chip'][data-state='done']"), "the file is still attached").toHaveCount(1);
  await expect(page.locator("[data-test='cto-chat-input']")).toHaveValue(draft);
  await expect(page.locator("[data-test='cto-chat-input']"), "the caret is back in the new box").toBeFocused();

  await page.locator("[data-test='cto-chat-input']").press("Enter");
  await expect.poll(() => held.posts).toBe(2);
  held.releaseAll();
  const turn = page.locator("[data-test='cto-chat-turn']", { hasText: draft });
  await expect(turn.locator("[data-test='cto-chat-sent-file']"), "the next message carries it").toHaveCount(1);

  expect(pageErrors, report()).toEqual([]);
});
