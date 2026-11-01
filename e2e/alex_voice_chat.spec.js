// [e2e] Talk to Alex by voice on /chat (task talk-to-alex-by-voice; epic
// .agents/epics/studio-voice.md, card 4). The page is the engine's agent chat on
// the admin's own thread with Alex (chat:alex:<user id>), with the engine's
// hold-to-talk recorder and microphone chip under it (chat/_voice,
// app/javascript/voice_chat.js). The server runs the MOCK transcriber (the
// test environment's default; Studio::VoiceTranscription::Mock answers "This is
// a mock transcript of your voice.") and the FAKE embedder
// (config.voice_embedder = "fake" in test: a fixed vector per
// window.studioFakeVoice), so nothing leaves this machine.
//
// THE MICROPHONE IS STUBBED before any page script runs, as studio-engine's
// e2e/voice_capture.spec.js does: getUserMedia answers a Web Audio oscillator
// at window.stubGain (0.3 a voice, 0 a muted microphone) wearing a device label.
//
// NOT @qa-readonly: it writes agent messages on the admin's chat:alex thread
// (no dispatcher runs here, so they stay pending) and saves, then deletes, the
// admin's voice.
//
// CONTROLS, run against this file:
//   - drop `voice` from the JSON body in voice_chat.js's send(): the stored
//     row loses envelope.voice and "spoken by" fails on the status line's
//     speaker (the server names nobody).
//   - drop the data-voice-chat-embedder attribute in chat/_voice: the take
//     carries no vector, the server answers Someone new, and the saved-voice
//     case fails.
const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockThirdPartyRequests } = require("./helpers");

const CHAT = "[data-studio-controller='agent-chat']";
const RECORDER = "[data-studio-controller='voice-recorder']";
const VOICE = "[data-test='voice-chat']";
const MOCK_TEXT = "This is a mock transcript of your voice.";
const PRIVACY = "When you speak to an agent, your recording is sent to OpenAI to turn it into text, then deleted. We never keep the audio.";
const FAKE_VOICE = "alex-test-voice";

async function stubMicrophone(page, { gain = 0.3 } = {}) {
  await page.addInitScript(({ gain, voice }) => {
    window.stubGain = gain;
    window.studioFakeVoice = voice;
    const mic = { deviceId: "mbp", label: "MacBook Pro Microphone (Built-in)" };
    const granted = () => sessionStorage.getItem("stub-mic-granted") === "1";
    const media = navigator.mediaDevices;
    media.enumerateDevices = async () => [{ kind: "audioinput", groupId: "", deviceId: granted() ? mic.deviceId : "", label: granted() ? mic.label : "" }];
    let source = null;
    media.getUserMedia = async () => {
      sessionStorage.setItem("stub-mic-granted", "1");
      if (!source) {
        const context = new AudioContext();
        const oscillator = context.createOscillator();
        oscillator.frequency.value = 220;
        const volume = context.createGain();
        oscillator.connect(volume);
        oscillator.start();
        source = { context, volume };
      }
      if (source.context.state === "suspended") await source.context.resume();
      source.volume.gain.value = window.stubGain;
      const out = source.context.createMediaStreamDestination();
      source.volume.connect(out);
      const track = out.stream.getAudioTracks()[0];
      Object.defineProperty(track, "label", { value: mic.label });
      track.getSettings = () => ({ deviceId: mic.deviceId });
      return out.stream;
    };
  }, { gain, voice: FAKE_VOICE });
}

// The admin's saved voice: the fake embedder's vector for FAKE_VOICE, saved
// through the /profile voice row's own endpoint (three takes, averaged).
async function saveVoice(page) {
  const status = await page.evaluate(async (voice) => {
    const { fakeVector } = await import("studio/voice_profile");
    const vector = fakeVector(voice);
    const token = document.querySelector("meta[name='csrf-token']")?.content || "";
    const response = await fetch("/profile/voice", {
      method: "POST", credentials: "same-origin",
      headers: { Accept: "application/json", "Content-Type": "application/json", "X-CSRF-Token": token },
      body: JSON.stringify({ voice: { model: "fake-256", embeddings: [vector, vector, vector] } })
    });
    return response.status;
  }, FAKE_VOICE);
  expect(status).toBe(200);
}

async function deleteVoice(page) {
  await page.evaluate(async () => {
    const token = document.querySelector("meta[name='csrf-token']")?.content || "";
    await fetch("/profile/voice", { method: "DELETE", credentials: "same-origin",
      headers: { Accept: "application/json", "X-CSRF-Token": token } });
  });
}

async function openChat(page) {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/chat");
  await expect(page.locator(CHAT)).toHaveAttribute("data-agent-chat-ready", "true");
  await expect(page.locator(RECORDER)).toHaveAttribute("data-voice-recorder-ready", "true");
}

async function holdToTalk(page, { holdMs = 700 } = {}) {
  const recorder = page.locator(RECORDER);
  const box = await recorder.locator("[data-voice-recorder-button]").boundingBox();
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  await page.mouse.down();
  await expect(recorder).toHaveAttribute("data-voice-recorder-state", "recording");
  await page.waitForTimeout(holdMs);
  await page.mouse.up();
  await expect(recorder).not.toHaveAttribute("data-voice-recorder-state", /recording|starting/);
}

const sideways = (page) => page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);

test.beforeEach(async ({ page }) => {
  await blockThirdPartyRequests(page);
});

test("hold to talk with a saved voice: the transcript posts to Alex's thread, spoken by the admin", async ({ page }) => {
  const { pageErrors, report } = watchPageErrors(page);
  await stubMicrophone(page);
  await openChat(page);
  await saveVoice(page);
  await openChat(page); // the page now names the embedder for this person's voice
  try {
    await expect(page.locator(VOICE)).toHaveAttribute("data-voice-chat-embedder", /"name":"fake"/);
    await expect(page.locator("[data-test='voice-chat-privacy']")).toHaveText(PRIVACY);

    const takes = [];
    page.on("request", (request) => {
      if (request.url().endsWith("/voice/takes") && request.method() === "POST") takes.push(request.postDataBuffer().toString("latin1"));
    });
    const sent = page.locator(`${CHAT} [data-test='agent-chat-sent']`);
    const before = await sent.count();

    await holdToTalk(page);

    await expect(page.locator(VOICE)).toHaveAttribute("data-voice-chat-state", "sent");
    await expect(page.locator("[data-test='voice-chat-status']")).toHaveText("Sent. Spoken by Alex Test.");
    await expect(sent).toHaveCount(before + 1);
    await expect(sent.last()).toHaveText(MOCK_TEXT);
    // Alex is now answering: the engine chat polls and shows the pending turn.
    await expect(page.locator(`${CHAT} [data-agent-chat-typing]`)).toBeVisible();

    expect(takes).toHaveLength(1);
    expect(takes[0]).toContain('name="voice[embedding]"');
    expect(takes[0]).toContain('name="voice[model]"');
    expect(await sideways(page)).toBeLessThanOrEqual(0);
    expect(pageErrors, report()).toEqual([]);
  } finally {
    await deleteVoice(page);
  }
});

test("with no saved voice the take still sends, spoken by Someone new", async ({ page }) => {
  await stubMicrophone(page);
  await openChat(page);
  await deleteVoice(page);
  await openChat(page);
  await expect(page.locator(VOICE)).not.toHaveAttribute("data-voice-chat-embedder", /.+/);
  const sent = page.locator(`${CHAT} [data-test='agent-chat-sent']`);
  const before = await sent.count();

  await holdToTalk(page);

  await expect(page.locator("[data-test='voice-chat-status']")).toHaveText("Sent. Spoken by Someone new.");
  await expect(sent).toHaveCount(before + 1);
  await expect(sent.last()).toHaveText(MOCK_TEXT);
});

test("a silent take is refused on the device, and nothing is sent", async ({ page }) => {
  await stubMicrophone(page, { gain: 0 });
  await openChat(page);
  let posts = 0;
  page.on("request", (request) => { if (request.url().endsWith("/voice/takes")) posts += 1; });

  await holdToTalk(page);

  await expect(page.locator(VOICE)).toHaveAttribute("data-voice-chat-state", "silent");
  await expect(page.locator("[data-test='voice-chat-status']")).toContainText("I couldn't hear anything");
  expect(posts).toBe(0);
});

test("refusals: voice not set up, and too many takes, each say so and send nothing", async ({ page }) => {
  await stubMicrophone(page);
  await openChat(page);
  const answers = [
    { status: 503, body: { error: "Voice isn't set up on this app yet, so I can't hear recordings. Type instead for now.", reason: "not_configured" },
      state: "not_configured", line: "Voice isn't set up on this app yet" },
    { status: 429, body: { error: "Too many requests. Try again later.", retry_after: 60 }, headers: { "Retry-After": "60" },
      state: "rate_limited", line: "Try again in 1 minute." }
  ];
  let chatPosts = 0;
  page.on("request", (request) => { if (request.url().endsWith("/agent_chat/messages")) chatPosts += 1; });
  for (const answer of answers) {
    await page.unroute("**/voice/takes");
    await page.route("**/voice/takes", (route) => route.fulfill({
      status: answer.status, contentType: "application/json", headers: answer.headers || {}, body: JSON.stringify(answer.body)
    }));
    await holdToTalk(page);
    await expect(page.locator(VOICE)).toHaveAttribute("data-voice-chat-state", answer.state);
    await expect(page.locator("[data-test='voice-chat-status']")).toContainText(answer.line);
  }
  expect(chatPosts).toBe(0);
});

test("dark mode at 390px: the talk button and chip read on the dark surface, 44px targets", async ({ page }) => {
  await page.emulateMedia({ colorScheme: "dark" });
  await stubMicrophone(page);
  await openChat(page);
  for (const selector of [".studio-recorder-button", ".studio-mic-chip"]) {
    const box = await page.locator(`${VOICE} ${selector}`).boundingBox();
    expect(box.height, `${selector} is a 44px target`).toBeGreaterThanOrEqual(44);
  }
  const colours = await page.evaluate(() => {
    const read = (selector) => getComputedStyle(document.querySelector(selector));
    return { privacy: read("[data-test='voice-chat-privacy']").color, body: getComputedStyle(document.body).backgroundColor };
  });
  expect(colours.privacy).not.toBe(colours.body);
  expect(await sideways(page)).toBeLessThanOrEqual(0);
});
