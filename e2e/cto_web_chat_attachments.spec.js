// [e2e] Files in the CTO web chat (.agents/epics/chat-media-design.md, step 1).
// The admin (linked to an owner-role person by e2e/seed.rb) opens Turf's chat
// and DROPS an image on the page: the drop zone shows, a chip with the file's
// name uploads it, and the send carries it. The sent turn shows the picture,
// served through the hub's owner-only redirect. The spec then plays the
// dispatcher through the real mailbox API: the claim's context bundle names the
// file with an expiring URL that serves its bytes, and the answer streams into
// the chat. A file of the wrong type gets a chip that says why and is never sent.
//
// NOT @qa-readonly: it writes agent messages and uploads a file. Nothing here
// talks to Discord, R2 or Claude (the test env stores files on disk).
const fs = require("fs");
const path = require("path");
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink, watchPageErrors, VISITOR } = require("./helpers");

test.use({ storageState: VISITOR });

const PNG = fs.readFileSync(path.join(__dirname, "..", "test", "fixtures", "files", "chat", "probe.png"));

async function apiToken(page) {
  await page.goto("/agents/activities");
  return page.getAttribute("meta[name='e2e-api-token']", "content");
}

// A drag of real files, as the browser's own drop would carry them.
async function dropFiles(page, files) {
  const transfer = await page.evaluateHandle((list) => {
    const dt = new DataTransfer();
    for (const f of list) dt.items.add(new File([new Uint8Array(f.bytes)], f.name, { type: f.type }));
    return dt;
  }, files.map((f) => ({ name: f.name, type: f.type, bytes: Array.from(f.bytes) })));
  await page.dispatchEvent("[data-test='cto-chat']", "dragenter", { dataTransfer: transfer });
  await expect(page.locator("[data-test='cto-chat-drop']")).toBeVisible();
  await page.dispatchEvent("[data-test='cto-chat']", "dragover", { dataTransfer: transfer });
  await page.dispatchEvent("[data-test='cto-chat']", "drop", { dataTransfer: transfer });
  await expect(page.locator("[data-test='cto-chat-drop']")).toBeHidden();
}

test("the owner drops an image on the chat, sees its chip, sends it, and the answer arrives", async ({ page }) => {
  const { pageErrors, report } = watchPageErrors(page);
  await loginWithMagicLink(page, "alex@test.com");
  const token = await apiToken(page);
  const auth = { Authorization: `Bearer ${token}`, "Content-Type": "application/json" };
  const worker = `e2e-files-${Date.now()}`;

  await page.goto("/applications/turf-monster/chat");
  await expect(page.locator("turbo-cable-stream-source[channel='CtoChatChannel']")).toHaveAttribute("connected", "");
  await expect(page.locator("[data-test='cto-chat-attach']")).toBeVisible();

  // A wrong type is refused on its chip, with the reason, and never rides the form.
  await dropFiles(page, [{ name: "notes.txt", type: "text/plain", bytes: Buffer.from("not a picture") }]);
  const bad = page.locator("[data-test='cto-chat-chip']", { hasText: "notes.txt" });
  await expect(bad).toHaveAttribute("data-state", "failed");
  await expect(bad.locator("[data-test='cto-chat-chip-error']")).toContainText("not an image or a PDF");
  await expect(bad).toHaveClass(/border-danger/);
  await expect(bad).not.toHaveClass(/border-subtle/);
  // A send with a failed file on it does not go: the composer says why.
  await page.locator("[data-test='cto-chat-input']").fill("with a broken file");
  await page.locator("[data-test='cto-chat-input']").press("Enter");
  await expect(page.locator("[data-test='cto-chat-attach-error']")).toContainText("A file did not upload");
  await expect(page.locator("[data-test='cto-chat-turn']", { hasText: "with a broken file" })).toHaveCount(0);
  const removeBox = await bad.locator("[data-test='cto-chat-chip-remove']").boundingBox();
  expect(removeBox.width).toBeGreaterThanOrEqual(24);
  expect(removeBox.height).toBeGreaterThanOrEqual(24);
  await bad.locator("[data-test='cto-chat-chip-remove']").click();
  await page.locator("[data-test='cto-chat-input']").fill("");
  await expect(bad).toHaveCount(0);

  await dropFiles(page, [{ name: "probe.png", type: "image/png", bytes: PNG }]);
  const chip = page.locator("[data-test='cto-chat-chip']", { hasText: "probe.png" });
  await expect(chip).toHaveCount(1);
  await expect(chip).toHaveAttribute("data-state", "done");
  await expect(page.locator("#cto-chat-form input[type='hidden'][name='cto_chat[attachments][]']")).toHaveCount(1);

  const text = `What is on this screen? ${Date.now()}`;
  const input = page.locator("[data-test='cto-chat-input']");
  await input.fill(text);
  await input.press("Enter");
  const turn = page.locator("[data-test='cto-chat-turn']", { hasText: text });
  await expect(turn).toHaveCount(1);
  await expect(turn).toHaveAttribute("data-status", "received");
  await expect(page.locator("[data-test='cto-chat-chip']")).toHaveCount(0);

  // The sent picture loads through the hub's owner-only redirect.
  const picture = turn.locator("[data-test='cto-chat-sent-file'][data-kind='image'] img");
  await expect(picture).toHaveAttribute("src", /^\/applications\/turf-monster\/chat\/attachments\/\d+$/);
  await expect.poll(() => picture.evaluate((img) => img.complete && img.naturalWidth)).toBeGreaterThan(0);

  // The dispatcher's side, through the real API: claim, read the file from the context bundle, answer.
  const claimed = await page.request.post("/api/v1/agent_messages/claim", {
    headers: auth, data: { souls: ["turf_monster"], worker, channel: "web" },
  });
  const message = (await claimed.json()).data;
  expect(message.content).toBe(text);
  const context = await page.request.get(`/api/v1/agent_messages/${message.id}/context?worker=${worker}`, { headers: auth });
  const files = (await context.json()).data.attachments;
  expect(files.map((f) => [f.filename, f.content_type, f.kind])).toEqual([["probe.png", "image/png", "image"]]);
  const download = await page.request.get(files[0].url);
  expect(download.ok()).toBeTruthy();
  expect((await download.body()).length).toBe(PNG.length);

  const done = await page.request.post(`/api/v1/agent_messages/${message.id}/complete`, {
    headers: auth, data: { worker, response_text: "A **yellow circle** beside a white bar." },
  });
  expect(done.ok()).toBeTruthy();
  const reply = turn.locator("[data-test='cto-chat-reply']");
  await expect(reply).toContainText("A yellow circle beside a white bar.");
  await expect(turn).toHaveAttribute("data-status", "completed");

  // A phone: the composer and its Attach button stay on screen, nothing runs off the side.
  await page.setViewportSize({ width: 390, height: 844 });
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
  expect(overflow, "nothing runs off the side at 390px").toBeLessThanOrEqual(0);
  await expect(page.locator("[data-test='cto-chat-attach']")).toBeInViewport();

  expect(pageErrors, report()).toHaveLength(0);
});
