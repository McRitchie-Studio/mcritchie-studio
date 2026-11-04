// [unit] voice_chat: hold to talk to Alex on /chat (task talk-to-alex-by-voice).
// The refusal lines for every answer POST /voice/takes can give, the take's
// multipart body, the message's `voice`, and one take end to end against a
// stand-in page and fetch: embed when a saved voice is named, transcribe, then
// send the words with `voice` and say the speaker the SERVER kept.
import { test } from "node:test";
import assert from "node:assert/strict";

import {
  MESSAGES, bindVoiceChat, csrfToken, parseEmbedder, refusalFor, retryHint, takeForm, voiceMetadata
} from "../../app/javascript/voice_chat.js";

class StubFormData {
  constructor() { this.entries = []; }
  append(name, value, filename) { this.entries.push([name, value, filename]); }
  get(name) { const hit = this.entries.find(([n]) => n === name); return hit ? hit[1] : null; }
  has(name) { return this.entries.some(([n]) => n === name); }
}

test("refusals: each answer from /voice/takes has its own state and line", () => {
  assert.deepEqual(refusalFor(503, { error: "Voice isn't set up on this app yet, so I can't hear recordings. Type instead for now.", reason: "not_configured" }),
    { state: "not_configured", message: "Voice isn't set up on this app yet, so I can't hear recordings. Type instead for now." });
  assert.equal(refusalFor(503, { reason: "not_configured" }).message, MESSAGES.notConfigured, "an empty error still says voice is not set up");
  assert.deepEqual(refusalFor(422, { error: "I couldn't hear any words in that.", reason: "no_speech" }),
    { state: "no_speech", message: "I couldn't hear any words in that." });
  assert.equal(refusalFor(503, { reason: "transcriber_failed", retry: true }).message, MESSAGES.unavailable);
  assert.equal(refusalFor(401, {}).state, "refused");
  assert.equal(refusalFor(413, { error: "That recording is too long to send." }).message, "That recording is too long to send.");
  assert.equal(refusalFor(500, { error: "<b>stack</b>" }).message, MESSAGES.failed, "an unexpected status never shows the server's words");
});

test("429: rate limited, with the wait from Retry-After or retry_after", () => {
  assert.deepEqual(refusalFor(429, {}, "40"), { state: "rate_limited", message: `${MESSAGES.rateLimited} Try again in 40 seconds.` });
  assert.equal(refusalFor(429, { retry_after: 600 }).message, `${MESSAGES.rateLimited} Try again in 10 minutes.`);
  assert.equal(refusalFor(429, {}).message, MESSAGES.rateLimited);
  assert.equal(retryHint(1), " Try again in 1 second.");
  assert.equal(retryHint(61), " Try again in 2 minutes.");
  assert.equal(retryHint("soon"), "");
});

test("voice: only the four fields the chat keeps, with safe defaults", () => {
  assert.deepEqual(voiceMetadata({ text: "hi", speaker: "Alex", score: 0.91, identified: true, check: "matched", duration_ms: 2100 }),
    { speaker: "Alex", score: 0.91, check: "matched", duration_ms: 2100 });
  assert.deepEqual(voiceMetadata({ text: "hi" }), { speaker: "Someone new", score: null, check: "no_embedding", duration_ms: null });
});

test("the take's body: audio, type and length always; the vector and model only together", () => {
  const blob = { size: 10 };
  const plain = takeForm({ blob, mimeType: "audio/webm;codecs=opus", durationMs: 1234.6 }, {}, StubFormData);
  assert.deepEqual(plain.entries, [["voice[audio]", blob, "take"], ["voice[mime_type]", "audio/webm;codecs=opus", undefined], ["voice[duration_ms]", "1235", undefined]]);

  const embedded = takeForm({ blob, durationMs: 900 }, { embedding: [0.1, 0.2], model: "fake-256" }, StubFormData);
  assert.equal(embedded.get("voice[embedding]"), "[0.1,0.2]");
  assert.equal(embedded.get("voice[model]"), "fake-256");
  assert.equal(takeForm({ blob, durationMs: 0 }, { embedding: [0.1] }, StubFormData).has("voice[embedding]"), false, "no model, no vector");
  assert.equal(takeForm({ blob, durationMs: 0 }, {}, StubFormData).get("voice[duration_ms]"), "1");
});

test("the embedder config is read only when it names an embedder and its id", () => {
  assert.deepEqual(parseEmbedder('{"name":"fake","id":"fake-256","size":256}'), { name: "fake", id: "fake-256", size: 256 });
  assert.equal(parseEmbedder(null), null);
  assert.equal(parseEmbedder("{not json"), null);
  assert.equal(parseEmbedder('{"name":"fake"}'), null);
});

test("the CSRF token: the meta tag, else the chat form's hidden field", () => {
  const withMeta = { querySelector: (s) => (s.includes("csrf-token") ? { getAttribute: () => "meta-token" } : null) };
  const withField = { querySelector: (s) => (s.includes("authenticity_token") ? { value: "form-token" } : null) };
  assert.equal(csrfToken(withMeta), "meta-token");
  assert.equal(csrfToken(withField), "form-token");
  assert.equal(csrfToken({ querySelector: () => null }), null);
});

// A stand-in /chat: the engine chat (form, input, retry, log) and the voice section.
function page({ embedder = null } = {}) {
  const turns = [];
  const clicks = { retry: 0 };
  const input = { value: "" };
  const chat = {
    dataset: { agentChatSoul: "alex" },
    querySelector(selector) {
      if (selector === "[data-agent-chat-form]") return { getAttribute: () => "/agent_chat/messages" };
      if (selector === "[data-agent-chat-input]") return input;
      if (selector === "[data-agent-chat-retry]") return { click: () => { clicks.retry += 1; } };
      return null;
    },
    querySelectorAll: () => turns.map((key) => ({ dataset: { turnKey: key } }))
  };
  const status = { textContent: "" };
  const wrapper = { querySelector: (s) => (s.includes("agent-chat") ? chat : null) };
  const section = {
    dataset: { voiceChatSoul: "alex", voiceChatName: "Alex", voiceChatTakesUrl: "/voice/takes", voiceChatState: "idle" },
    getAttribute: (name) => (name === "data-voice-chat-embedder" ? embedder : null),
    querySelector: (s) => (s === "[data-voice-chat-status]" ? status : null),
    closest: (s) => (s === "[data-voice-chat-page]" ? wrapper : null)
  };
  const listeners = {};
  const doc = {
    querySelector: (s) => (s.includes("csrf-token") ? { getAttribute: () => "tok" } : null),
    addEventListener: (type, fn) => { listeners[type] = fn; },
    removeEventListener: (type) => { delete listeners[type]; }
  };
  return { doc, section, status, input, turns, clicks, listeners };
}

function answer(status, body, headers = {}) {
  return { status, ok: status >= 200 && status < 300, json: async () => body, headers: { get: (name) => headers[name] ?? null } };
}

test("a take with a saved voice: embedded, transcribed, then sent with voice; the status names who the server kept", async () => {
  const p = page({ embedder: '{"name":"fake","id":"fake-256","size":256}' });
  const calls = [];
  const fetch = async (url, options) => {
    calls.push({ url, options });
    if (url === "/voice/takes") return answer(200, { text: "What's on today?", speaker: "Alex McRitchie", score: 0.93, identified: true, check: "matched", duration_ms: 1800 });
    return answer(201, { turn: { id: 41, role: "user", text: "What's on today?", status: "pending" }, voice: { speaker: "Alex McRitchie" } });
  };
  const embedder = { id: "fake-256", embed: async () => [0.5, 0.25], warm: () => {} };
  const voice = bindVoiceChat(p.doc, { fetch, loadEmbedder: async () => embedder, setTimer: () => {}, FormDataClass: StubFormData });

  await voice.handleTake(p.section, { blob: { size: 4 }, mimeType: "audio/webm", durationMs: 1800 });

  assert.equal(calls.length, 2);
  const take = calls[0].options;
  assert.equal(take.headers["X-CSRF-Token"], "tok");
  assert.equal(take.body.get("voice[embedding]"), "[0.5,0.25]");
  assert.equal(take.body.get("voice[model]"), "fake-256");
  assert.equal(calls[1].url, "/agent_chat/messages");
  assert.deepEqual(JSON.parse(calls[1].options.body), {
    soul: "alex", text: "What's on today?", voice: { speaker: "Alex McRitchie", score: 0.93, check: "matched", duration_ms: 1800 }
  });
  assert.equal(p.section.dataset.voiceChatState, "sent");
  assert.equal(p.status.textContent, "Sent. Spoken by Alex McRitchie.");
  assert.equal(p.clicks.retry, 1, "the engine chat is told to poll for the new turn");
  voice.destroy();
});

test("no saved voice: no embedder loads and the take goes without a vector", async () => {
  const p = page();
  let loads = 0;
  const bodies = [];
  const fetch = async (url, options) => {
    bodies.push(options.body);
    return url === "/voice/takes"
      ? answer(200, { text: "hello", speaker: "Someone new", score: null, check: "no_profile", duration_ms: 700 })
      : answer(201, { turn: { id: 7 }, voice: { speaker: "Someone new" } });
  };
  const voice = bindVoiceChat(p.doc, { fetch, loadEmbedder: async () => { loads += 1; }, setTimer: () => {}, FormDataClass: StubFormData });
  await voice.handleTake(p.section, { blob: { size: 4 }, durationMs: 700 });
  assert.equal(loads, 0);
  assert.equal(bodies[0].has("voice[embedding]"), false);
  assert.equal(p.status.textContent, "Sent. Spoken by Someone new.");
});

test("an embedder that fails still transcribes, without a vector", async () => {
  const p = page({ embedder: '{"name":"wespeaker","id":"w-1"}' });
  const bodies = [];
  const fetch = async (url, options) => {
    bodies.push(options.body);
    return url === "/voice/takes" ? answer(200, { text: "hi", check: "no_embedding" }) : answer(201, { turn: { id: 8 } });
  };
  const voice = bindVoiceChat(p.doc, { fetch, loadEmbedder: async () => ({ id: "w-1", embed: async () => { throw new Error("model blocked"); } }), setTimer: () => {}, FormDataClass: StubFormData });
  await voice.handleTake(p.section, { blob: { size: 4 }, durationMs: 700 });
  assert.equal(bodies[0].has("voice[embedding]"), false);
  assert.equal(p.status.textContent, MESSAGES.sentPlain, "no kept voice in the answer: the page names nobody");
});

test("a refused take sends nothing and says why; a refused send keeps the words in the box", async () => {
  const notSetUp = page();
  const urls = [];
  let voice = bindVoiceChat(notSetUp.doc, {
    fetch: async (url) => { urls.push(url); return answer(503, { error: "Voice isn't set up on this app yet, so I can't hear recordings. Type instead for now.", reason: "not_configured" }); },
    setTimer: () => {}, FormDataClass: StubFormData
  });
  await voice.handleTake(notSetUp.section, { blob: { size: 4 }, durationMs: 700 });
  assert.deepEqual(urls, ["/voice/takes"]);
  assert.equal(notSetUp.section.dataset.voiceChatState, "not_configured");
  assert.match(notSetUp.status.textContent, /Voice isn't set up/);

  const capped = page();
  voice = bindVoiceChat(capped.doc, {
    fetch: async (url) => (url === "/voice/takes" ? answer(200, { text: "keep these words", check: "no_profile" }) : answer(429, { error: "Slow down." })),
    setTimer: () => {}, FormDataClass: StubFormData
  });
  await voice.handleTake(capped.section, { blob: { size: 4 }, durationMs: 700 });
  assert.equal(capped.section.dataset.voiceChatState, "rate_limited");
  assert.equal(capped.input.value, "keep these words");
  assert.match(capped.status.textContent, /^Slow down\. Couldn't send that to Alex/);
});

test("a silent take only says so", () => {
  const p = page();
  bindVoiceChat(p.doc, { fetch: async () => assert.fail("nothing is sent"), setTimer: () => {} });
  p.listeners["studio:voice-recorder:silent"]({ target: { closest: () => p.section } });
  assert.equal(p.section.dataset.voiceChatState, "silent");
  assert.equal(p.status.textContent, MESSAGES.silent);
});

test("a model slower than EMBED_WAIT_MS is not waited for: the take goes without a vector", async () => {
  const p = page({ embedder: '{"name":"wespeaker","id":"w-1"}' });
  const bodies = [];
  const waits = [];
  const fetch = async (url, options) => {
    bodies.push(options.body);
    return url === "/voice/takes" ? answer(200, { text: "hi", check: "no_embedding" }) : answer(201, { turn: { id: 9 } });
  };
  // The deadline fires at once; the embedder never answers.
  const setTimer = (fn, ms) => { waits.push(ms); fn(); };
  const voice = bindVoiceChat(p.doc, { fetch, loadEmbedder: async () => ({ id: "w-1", embed: () => new Promise(() => {}) }), setTimer, FormDataClass: StubFormData });
  await voice.handleTake(p.section, { blob: { size: 4 }, durationMs: 700 });
  assert.equal(bodies[0].has("voice[embedding]"), false);
  assert.ok(waits.includes(8000), "the deadline is EMBED_WAIT_MS");
});
