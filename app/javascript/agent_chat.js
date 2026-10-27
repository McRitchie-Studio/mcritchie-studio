// The shared agent web chat (app/views/agent_chats; first page: the CTO chat at
// /applications/:slug/chat). The page's Turbo stream appends turns, replaces a
// turn when its answer lands, and pulses "typing…" into the typing slot. This
// module only keeps the view honest around those streams:
//
//   - the log opens at its newest turn, and after every stream render keeps a
//     reader who was at the end there (chat_follow.js; one scrolled up stays);
//   - a typing pulse fades data-fade-seconds after it arrived, so a run that
//     dies stops "typing" within seconds (the dispatcher pulses every 7s), and
//     a pulse older than an answer already shown is dropped at once;
//   - a pulse carries its phase (data-phase: thinking, then typing). Each
//     pulse redraws the indicator, so the phase the old one showed is carried
//     onto the new one for a frame and then let go, and the CSS
//     (agent_typing.css) crossfades the swap; every redraw also gets the page
//     clock's place in the motion's beat (--agent-typing-sync), so the ring,
//     shimmer and dots run on without a restart;
//   - Enter sends, Shift+Enter is a new line, and the composer keeps focus;
//   - while a send posts, its status line reads "Sending…" for a screen reader;
//   - a send spends the composer the moment Turbo has read it (startSend): a
//     fresh client id, the box emptied, its files' tokens set aside. The sent
//     turn is broadcast as well as answered, and the broadcast can land first,
//     so the owner may write again while the OLD composer is still on the page.
//     That message once rode the last one's client id and AgentMessages::WebIngest
//     kept it as a double submit: it vanished (task shell-growth-spec-stops-flaking).
//     When the answer's fresh composer lands, a draft typed meanwhile is carried
//     into it (carriedDraft); a send that never reached the server puts its text
//     back. One empty send while a send posts is a double submit, and is dropped.
//
// Its hooks keep their cto-chat names (data-cto-chat-*, #cto-chat-typing, the
// AgentMessages::WebChat targets) for every agent, so the CTO page is unchanged.
// Imported by application.js on every page, once per load; every listener is
// delegated on document and does nothing where there is no chat, so a Turbo
// visit to or back to the chat needs no re-binding. "cto_chat" is pinned to
// this file too (config/importmap.rb), so the old import still loads it.
import { follow, stickIfFollowing } from "chat_follow";

const LOG = "[data-cto-chat-scroll]";
const TYPING = "cto-chat-typing";
const FORM = "[data-cto-chat-form]";
const INDICATOR = "[data-test='cto-chat-typing'][data-phase]";
// agent_typing.css's --agent-typing-beat, in ms: every loop divides it.
export const BEAT_MS = 2400;
let fadeTimer = null;

// Where an indicator lives, the same before and after a redraw: its typing slot
// on the CTO chat (#cto-chat-typing), its turn on /build (#build-turn-N).
export function indicatorKey(indicator) {
  return indicator.parentElement?.closest?.("[id]")?.id || "";
}

// key -> phase, for every indicator in `root` (read before a stream renders).
export function phasesIn(root) {
  const phases = new Map();
  root?.querySelectorAll?.(INDICATOR).forEach((indicator) => {
    phases.set(indicatorKey(indicator), indicator.dataset.phase);
  });
  return phases;
}

// A redrawn indicator whose phase moved on: show the old phase for one frame,
// then the new, so the CSS transition runs. Returns true when it swapped.
export function carryPhase(indicator, previous, frame = (fn) => requestAnimationFrame(fn)) {
  const next = indicator.dataset.phase;
  if (!previous || previous === next) return false;
  indicator.dataset.phase = previous;
  void indicator.offsetWidth; // commit the old look before the swap
  frame(() => {
    indicator.dataset.phase = next;
  });
  return true;
}

// The negative delay that puts a fresh animation at the page clock's place in
// the beat, as a CSS time.
export function syncDelay(now = Date.now()) {
  return `-${now % BEAT_MS}ms`;
}

// A fresh client id for the composer's next send (AgentMessages::WebIngest::CLIENT_ID
// takes a UUID). Empty where the browser has none: the server then mints one.
export function freshClientId(random = () => globalThis.crypto?.randomUUID?.()) {
  return random() || "";
}

// The send Turbo has just read out of `form` is on its way: give the form a fresh
// client id, empty its box, and set its files' tokens aside, so a second send from
// this same form is a message of its own, never the first again. Returns the text
// that was sent, for restoreSend.
export function startSend(form, random) {
  const field = form.querySelector("textarea");
  const text = field?.value || "";
  const id = form.querySelector("input[name$='[client_id]']");
  if (id) id.value = freshClientId(random);
  if (field) field.value = "";
  form.querySelectorAll("input[name$='[attachments][]']").forEach((token) => { token.disabled = true; });
  return text;
}

// A send whose answer never came (Turbo's submit-end carries an error): its text,
// files and client id go back in, unless something new was typed meanwhile. The id
// matters: the server may have stored the send before the answer was lost, and a
// retry on the same id is then kept once (WebIngest), not stored twice.
export function restoreSend(form, text, clientId) {
  const field = form.querySelector("textarea");
  form.querySelectorAll("input[name$='[attachments][]']").forEach((token) => { token.disabled = false; });
  if (!field || field.value.trim() !== "" || !text) return false;
  field.value = text;
  const id = form.querySelector("input[name$='[client_id]']");
  if (id && clientId) id.value = clientId;
  return true;
}

// What a composer redrawn by the server holds: what the server drew there (a
// refused send's text, echoed back with its reason), else what was being typed
// while the send posted.
export function carriedDraft(drawn, typed) {
  return (drawn || "").trim() !== "" ? drawn : (typed || "");
}

// A stream that redraws a chat composer: the composer it replaces, or null.
function composerTarget(stream) {
  if (!stream?.getAttribute) return null;
  if (!["replace", "update"].includes(stream.getAttribute("action"))) return null;
  const target = document.getElementById(stream.getAttribute("target") || "");
  return target?.matches?.(FORM) ? target : null;
}

function settleIndicators(before, now = Date.now()) {
  document.querySelectorAll(INDICATOR).forEach((indicator) => {
    indicator.style.setProperty("--agent-typing-sync", syncDelay(now));
    carryPhase(indicator, before?.get(indicatorKey(indicator)));
  });
}

function newestReply() {
  let newest = 0;
  document.querySelectorAll(`${LOG} [data-replied-at]`).forEach((turn) => {
    newest = Math.max(newest, Number(turn.dataset.repliedAt) || 0);
  });
  return newest;
}

function settleTyping() {
  const slot = document.getElementById(TYPING);
  if (!slot) return;
  const pulse = slot.querySelector("[data-typing-at]");
  clearTimeout(fadeTimer);
  if (!pulse) return;
  if (Number(pulse.dataset.typingAt) <= newestReply()) {
    slot.replaceChildren();
    return;
  }
  const seconds = Number(slot.dataset.fadeSeconds) || 12;
  fadeTimer = setTimeout(() => slot.replaceChildren(), seconds * 1000);
}

function afterRender() {
  requestAnimationFrame(() => {
    settleTyping();
    stickIfFollowing(document.querySelector(LOG));
  });
}

if (typeof document !== "undefined") {
  document.addEventListener("turbo:before-stream-render", (event) => {
    const original = event.detail.render;
    event.detail.render = async (stream) => {
      const before = phasesIn(document);
      const composer = composerTarget(stream);
      const typed = composer?.querySelector("textarea")?.value || "";
      const formId = composer?.id;
      await original(stream);
      if (formId && typed.trim() !== "") {
        const field = document.getElementById(formId)?.querySelector("textarea");
        if (field && field.value !== carriedDraft(field.value, typed)) {
          field.value = carriedDraft(field.value, typed);
          field.dispatchEvent(new Event("input", { bubbles: true }));
        }
      }
      settleIndicators(before);
      afterRender();
    };
  });

  // Capture phase, before Turbo reads the form: an empty send while one posts is
  // the same send twice (a second Enter, a second tap), so it is dropped.
  document.addEventListener("submit", (event) => {
    const form = event.target.closest?.(FORM);
    if (!form || form.getAttribute("aria-busy") !== "true") return;
    if ((form.querySelector("textarea")?.value || "").trim() !== "") return;
    event.preventDefault();
    event.stopImmediatePropagation();
  }, true);

  document.addEventListener("keydown", (event) => {
    const input = event.target;
    if (!(input instanceof HTMLTextAreaElement) || !input.closest(FORM)) return;
    if (event.key !== "Enter" || event.shiftKey || event.isComposing) return;
    event.preventDefault();
    if (input.value.trim() !== "") input.form.requestSubmit();
  });

  // The send button is an icon, so a screen reader hears "Sending…" from the
  // composer's polite status line ([data-composer-status]) while the post runs.
  function announce(form, text) {
    const status = form?.querySelector("[data-composer-status]");
    if (status) status.textContent = text;
  }

  const sending = new WeakMap();

  document.addEventListener("turbo:submit-start", (event) => {
    const form = event.target.closest?.(FORM);
    announce(form, "Sending…");
    // Keyed by the submission: a send aborted by the next one ends after it starts.
    const clientId = form?.querySelector("input[name$='[client_id]']")?.value;
    if (form && event.detail?.formSubmission) sending.set(event.detail.formSubmission, { text: startSend(form), clientId });
  });

  document.addEventListener("turbo:submit-end", (event) => {
    if (!event.target.closest?.(FORM) && !event.target.matches?.(FORM)) return;
    const form = event.target.closest(FORM);
    const submission = event.detail?.formSubmission;
    const sent = submission && sending.get(submission);
    if (event.detail?.error && sent) restoreSend(form, sent.text, sent.clientId);
    if (submission) sending.delete(submission);
    announce(form, "");
    requestAnimationFrame(() => document.querySelector(`${FORM} textarea`)?.focus());
  });

  function init() {
    const log = document.querySelector(LOG);
    if (!log) return;
    follow(log);
    settleIndicators(null);
    settleTyping();
  }

  document.addEventListener("turbo:load", init);
  init();
}
