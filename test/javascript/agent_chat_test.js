// [unit] agent_chat: the thinking/typing swap (task chat-thinking-versus-typing).
// A pulse redraws the indicator, so the phase the old one showed is carried onto
// the new one for one frame and then let go (the CSS crossfades the change); the
// same phase is left alone; and each redraw's motion is put at the page clock's
// place in the beat, so it never restarts. Driven with stand-in elements.
import { test } from "node:test";
import assert from "node:assert/strict";

import { BEAT_MS, addChips, carriedDraft, carryPhase, emptyRepeat, focusComposer, freshClientId, indicatorKey, markBusy, phasesIn, restoreSend, sendFailed, startSend, syncDelay, trackSend } from "../../app/javascript/agent_chat.js";

function indicator(phase, slotId = "cto-chat-typing") {
  const slot = { id: slotId, closest: () => slot };
  return { dataset: { phase }, offsetWidth: 120, parentElement: slot };
}

function frames() {
  const queued = [];
  const frame = (fn) => queued.push(fn);
  frame.flush = () => queued.splice(0).forEach((fn) => fn());
  return frame;
}

test("thinking to typing shows thinking for one frame, then typing", () => {
  const next = indicator("typing");
  const frame = frames();

  assert.equal(carryPhase(next, "thinking", frame), true);
  assert.equal(next.dataset.phase, "thinking", "the old look first, so the transition has somewhere to start");
  frame.flush();
  assert.equal(next.dataset.phase, "typing");
});

test("the same phase, or none before, is left as drawn", () => {
  const frame = frames();
  const same = indicator("thinking");
  assert.equal(carryPhase(same, "thinking", frame), false);
  assert.equal(same.dataset.phase, "thinking");

  const first = indicator("thinking");
  assert.equal(carryPhase(first, undefined, frame), false);
  frame.flush();
  assert.equal(first.dataset.phase, "thinking");
});

test("indicators are matched across a redraw by their slot or turn", () => {
  const cto = indicator("thinking", "cto-chat-typing");
  const build = indicator("typing", "build-turn-7");
  assert.equal(indicatorKey(cto), "cto-chat-typing");
  assert.equal(indicatorKey(build), "build-turn-7");

  const root = { querySelectorAll: () => [cto, build] };
  assert.deepEqual([...phasesIn(root)], [["cto-chat-typing", "thinking"], ["build-turn-7", "typing"]]);
  assert.equal(phasesIn(null).size, 0);
});

test("the sync delay is the clock's place in the beat, as a negative CSS time", () => {
  assert.equal(syncDelay(BEAT_MS * 1000 + 600), "-600ms");
  assert.equal(syncDelay(BEAT_MS * 3), "-0ms");
});

// [unit] The send that spends the composer (task shell-growth-spec-stops-flaking): a
// second send from the same form, before the first's answer redraws it, is a message of
// its own; a draft typed meanwhile survives the redraw; a send that never reached the
// server gets its text and files back.
const CHIP = "[data-chat-attachment-chip]";
const CHIPS = "[data-chat-attachments-chips]";
const TOKEN = "input[name$='[attachments][]']";

// A file chip: ready ("done") with its token field, or still uploading (no token yet).
function chip(token, state = "done") {
  const field = token ? { value: token } : null;
  return {
    token, holder: null, dataset: { state },
    querySelector: (sel) => (sel === TOKEN ? field : null),
    remove() {
      if (!this.holder) return;
      this.holder.list.splice(this.holder.list.indexOf(this), 1);
      this.holder = null;
    },
  };
}

// A composer: its box, client id, file list and busy mark, as the module reads them.
function composer({ text = "", clientId = "old-client-id-1", tokens = [], chips = [], busy = false, dataset = {} } = {}) {
  const field = { value: text, required: true, focused: false, focus() { this.focused = true; }, setSelectionRange(a, b) { this.caret = [a, b]; } };
  const id = { value: clientId };
  const holder = { list: [], append(c) { c.remove(); c.holder = holder; holder.list.push(c); } };
  [...tokens.map((t) => chip(t)), ...chips].forEach((c) => holder.append(c));
  const attrs = new Map(busy ? [["aria-busy", "true"]] : []);
  return {
    field, id, holder, dataset: { ...dataset },
    get tokenInputs() { return holder.list.map((c) => c.querySelector(TOKEN)).filter(Boolean); },
    getAttribute: (name) => (attrs.has(name) ? attrs.get(name) : null),
    setAttribute: (name, value) => attrs.set(name, String(value)),
    removeAttribute: (name) => attrs.delete(name),
    querySelector: (sel) => (sel === "textarea" ? field : sel === "input[name$='[client_id]']" ? id : sel === CHIPS ? holder : null),
    querySelectorAll: (sel) => (sel === CHIP ? [...holder.list] : sel === TOKEN ? holder.list.map((c) => c.querySelector(TOKEN)).filter(Boolean) : []),
  };
}

const tokensIn = (form) => form.tokenInputs.map((t) => t.value);

test("startSend gives the form a fresh client id, empties the box, takes its sent files off, and returns what was sent", () => {
  const form = composer({ text: "First message", tokens: ["tok-a"] });
  form.field.required = false; // a file rides it
  const sent = startSend(form, () => "fresh-uuid-0001");
  assert.equal(sent.text, "First message");
  assert.deepEqual(sent.files.map((c) => c.token), ["tok-a"]);
  assert.equal(form.id.value, "fresh-uuid-0001", "a second send from this form is not the first again");
  assert.equal(form.field.value, "");
  assert.deepEqual(tokensIn(form), [], "the first send's files do not ride the second");
  assert.equal(form.field.required, true, "with its files gone the box is required again");
});

test("freshClientId is empty where the browser has no randomUUID, so the server mints one", () => {
  assert.equal(freshClientId(() => undefined), "");
  assert.match(freshClientId(), /^[0-9a-f-]{36}$/);
});

test("carriedDraft keeps what was typed and a refused send's echo, never one over the other", () => {
  assert.equal(carriedDraft("", "still typing"), "still typing");
  assert.equal(carriedDraft("refused text", "still typing"), "refused text\nstill typing", "both, the echo first");
  assert.equal(carriedDraft("refused text", ""), "refused text");
  assert.equal(carriedDraft("refused text", "refused text"), "refused text", "an echo of what the box holds is not doubled");
  assert.equal(carriedDraft("refused text", "refused text, and more"), "refused text, and more", "the box already holds the echo");
  assert.equal(carriedDraft("", ""), "");
  assert.equal(carriedDraft("  ", "typed"), "typed");
});

test("restoreSend puts an unsent text and its files back, but never over a new draft", () => {
  const form = composer({ text: "Lost in transit", tokens: ["tok-a"] });
  const sent = startSend(form, () => "fresh-uuid-0002");
  assert.equal(restoreSend(form, sent, "old-client-id-1"), true);
  assert.equal(form.field.value, "Lost in transit");
  assert.deepEqual(tokensIn(form), ["tok-a"]);
  assert.equal(form.field.required, false, "a file rides it again");
  assert.equal(form.id.value, "old-client-id-1", "a retry of a send the server may have stored is kept once");

  const typed = composer({ text: "sent" });
  const gone = startSend(typed, () => "fresh-uuid-0003");
  typed.field.value = "a new draft";
  assert.equal(restoreSend(typed, gone, "old-client-id-1"), false);
  assert.equal(typed.field.value, "a new draft");
  assert.equal(typed.id.value, "fresh-uuid-0003", "the new draft keeps its own id");
});

test("sendFailed: a network error or a refused answer puts the send back; a success or an abort does not", () => {
  assert.equal(sendFailed({ error: new Error("offline") }), true);
  assert.equal(sendFailed({ success: false, fetchResponse: { statusCode: 429 } }), true, "an empty 429 draws no composer");
  assert.equal(sendFailed({ success: true, fetchResponse: { statusCode: 200 } }), false);
  assert.equal(sendFailed({ formSubmission: {} }), false, "a send aborted by the next one");
});

// [unit] Task composer-edge-cases: the six edges reviewers found around the send swap.

test("focus: focusComposer puts the caret back in the redrawn box, at the end of its text", () => {
  const fresh = composer({ text: "carried draft" });
  assert.equal(focusComposer(fresh), true);
  assert.equal(fresh.field.focused, true);
  assert.deepEqual(fresh.field.caret, [13, 13]);
  assert.equal(focusComposer(null), false);
});

test("ask draft: the set-aside draft goes back in the box as the ask leaves, and no later step overwrites it", () => {
  const form = composer({ text: "Can you give me three new theme ideas?", dataset: { askDraft: "make it feel like a lake cabin" } });
  const sent = startSend(form, () => "fresh-uuid-0004");
  assert.equal(sent.text, "Can you give me three new theme ideas?", "the ask is what posts");
  assert.equal(form.field.value, "make it feel like a lake cabin", "the visitor's words are back at once");
  assert.equal(form.dataset.askDraft, undefined, "set aside once, put back once");

  // The ask fails: the canned text does not go back over the draft.
  assert.equal(restoreSend(form, sent, "old-client-id-1"), false);
  assert.equal(form.field.value, "make it feel like a lake cabin");

  // A redraw (empty, or the ask echoed with its refusal) carries the draft.
  assert.equal(carriedDraft("", form.field.value), "make it feel like a lake cabin");
  assert.equal(carriedDraft("Can you give me three new theme ideas?", form.field.value),
    "Can you give me three new theme ideas?\nmake it feel like a lake cabin");

  // A later send with no ask leaves the box empty, as any send does.
  form.field.value = "next";
  startSend(form, () => "fresh-uuid-0005");
  assert.equal(form.field.value, "");
});

test("aria-busy: overlapping sends keep the composer busy until the LAST one settles", () => {
  const inflight = new Map();
  const form = composer();
  const first = {};
  const second = {};
  markBusy(form, trackSend(inflight, "cto-chat-form", first, true));
  markBusy(form, trackSend(inflight, "cto-chat-form", second, true));
  // The first, aborted by the second, ends after the second started.
  markBusy(form, trackSend(inflight, "cto-chat-form", first, false));
  assert.equal(form.getAttribute("aria-busy"), "true", "the second still posts");
  markBusy(form, trackSend(inflight, "cto-chat-form", second, false));
  assert.equal(form.getAttribute("aria-busy"), null);
  assert.equal(inflight.size, 0);
  assert.equal(trackSend(inflight, "cto-chat-form", first, false), 0, "an end twice never goes below none");
});

test("sent files: a failed send gets back only its own files, never another send's", () => {
  const form = composer({ text: "with a picture", tokens: ["tok-sent"] });
  startSend(form, () => "fresh-uuid-0006"); // stored by the server
  form.field.value = "with a PDF";
  form.holder.append(chip("tok-pdf"));
  const second = startSend(form, () => "fresh-uuid-0007");
  assert.equal(restoreSend(form, second, "fresh-uuid-0006"), true);
  assert.deepEqual(tokensIn(form), ["tok-pdf"], "the first send's file stays sent");
});

test("mid-flight files: addChips moves files attached while a send posted into the redrawn composer", () => {
  const old = composer({ chips: [chip("tok-new"), chip(null, "uploading")] });
  const fresh = composer();
  assert.equal(addChips(fresh, old.querySelectorAll(CHIP)), 2);
  assert.deepEqual(fresh.holder.list.map((c) => c.dataset.state), ["done", "uploading"], "an upload still running moves too");
  assert.deepEqual(old.holder.list, []);
  assert.equal(fresh.field.required, false, "the files ride it, so the box is not required");

  // A refused send's files come back drawn by the server: not doubled.
  const drawn = composer({ tokens: ["tok-new"] });
  assert.equal(addChips(drawn, [chip("tok-new")]), 0);
  assert.deepEqual(tokensIn(drawn), ["tok-new"]);
});

test("files-only send: an empty send while one posts is a repeat only when it carries no files", () => {
  assert.equal(emptyRepeat(composer({ busy: true })), true, "a second Enter or tap is the same send twice");
  assert.equal(emptyRepeat(composer({ busy: true, tokens: ["tok-a"] })), false, "files with no text are a message");
  assert.equal(emptyRepeat(composer({ busy: true, chips: [chip(null, "uploading")] })), false, "files still uploading are held, not dropped");
  assert.equal(emptyRepeat(composer({ busy: true, text: "hi" })), false);
  assert.equal(emptyRepeat(composer()), false, "nothing posting: the browser and the server answer it");
});
