// [unit] agent_chat: the thinking/typing swap (task chat-thinking-versus-typing).
// A pulse redraws the indicator, so the phase the old one showed is carried onto
// the new one for one frame and then let go (the CSS crossfades the change); the
// same phase is left alone; and each redraw's motion is put at the page clock's
// place in the beat, so it never restarts. Driven with stand-in elements.
import { test } from "node:test";
import assert from "node:assert/strict";

import { BEAT_MS, carriedDraft, carryPhase, freshClientId, indicatorKey, phasesIn, restoreSend, startSend, syncDelay } from "../../app/javascript/agent_chat.js";

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
function composer({ text = "", clientId = "old-client-id-1", tokens = [] } = {}) {
  const field = { value: text };
  const id = { value: clientId };
  const tokenInputs = tokens.map((value) => ({ value, disabled: false }));
  return {
    field, id, tokenInputs,
    querySelector: (sel) => (sel === "textarea" ? field : sel === "input[name$='[client_id]']" ? id : null),
    querySelectorAll: (sel) => (sel === "input[name$='[attachments][]']" ? tokenInputs : []),
  };
}

test("startSend gives the form a fresh client id, empties the box, sets its files aside, and returns the text", () => {
  const form = composer({ text: "First message", tokens: ["tok-a"] });
  assert.equal(startSend(form, () => "fresh-uuid-0001"), "First message");
  assert.equal(form.id.value, "fresh-uuid-0001", "a second send from this form is not the first again");
  assert.equal(form.field.value, "");
  assert.equal(form.tokenInputs[0].disabled, true, "the first send's files do not ride the second");
});

test("freshClientId is empty where the browser has no randomUUID, so the server mints one", () => {
  assert.equal(freshClientId(() => undefined), "");
  assert.match(freshClientId(), /^[0-9a-f-]{36}$/);
});

test("carriedDraft keeps what was typed unless the server drew text (a refused send's echo)", () => {
  assert.equal(carriedDraft("", "still typing"), "still typing");
  assert.equal(carriedDraft("refused text", "still typing"), "refused text");
  assert.equal(carriedDraft("", ""), "");
  assert.equal(carriedDraft("  ", "typed"), "typed");
});

test("restoreSend puts an unsent text and its files back, but never over a new draft", () => {
  const form = composer({ text: "Lost in transit", tokens: ["tok-a"] });
  startSend(form, () => "fresh-uuid-0002");
  assert.equal(restoreSend(form, "Lost in transit", "old-client-id-1"), true);
  assert.equal(form.field.value, "Lost in transit");
  assert.equal(form.tokenInputs[0].disabled, false);
  assert.equal(form.id.value, "old-client-id-1", "a retry of a send the server may have stored is kept once");

  const typed = composer({ text: "sent" });
  startSend(typed, () => "fresh-uuid-0003");
  typed.field.value = "a new draft";
  assert.equal(restoreSend(typed, "sent", "old-client-id-1"), false);
  assert.equal(typed.field.value, "a new draft");
  assert.equal(typed.id.value, "fresh-uuid-0003", "the new draft keeps its own id");
});
