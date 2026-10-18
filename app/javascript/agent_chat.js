// The shared agent web chat (app/views/agent_chats; first page: the CTO chat at
// /applications/:slug/chat). The page's Turbo stream appends turns, replaces a
// turn when its answer lands, and pulses "typing…" into the typing slot. This
// module only keeps the view honest around those streams:
//
//   - the log scrolls to the newest turn on load and after every stream render;
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
//   - while a send posts, its status line reads "Sending…" for a screen reader.
//
// Its hooks keep their cto-chat names (data-cto-chat-*, #cto-chat-typing, the
// AgentMessages::WebChat targets) for every agent, so the CTO page is unchanged.
// Imported by application.js on every page, once per load; every listener is
// delegated on document and does nothing where there is no chat, so a Turbo
// visit to or back to the chat needs no re-binding. "cto_chat" is pinned to
// this file too (config/importmap.rb), so the old import still loads it.
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

function settleIndicators(before, now = Date.now()) {
  document.querySelectorAll(INDICATOR).forEach((indicator) => {
    indicator.style.setProperty("--agent-typing-sync", syncDelay(now));
    carryPhase(indicator, before?.get(indicatorKey(indicator)));
  });
}

function scrollToEnd() {
  const log = document.querySelector(LOG);
  if (log) log.scrollTop = log.scrollHeight;
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
    scrollToEnd();
  });
}

if (typeof document !== "undefined") {
  document.addEventListener("turbo:before-stream-render", (event) => {
    const original = event.detail.render;
    event.detail.render = async (stream) => {
      const before = phasesIn(document);
      await original(stream);
      settleIndicators(before);
      afterRender();
    };
  });

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

  document.addEventListener("turbo:submit-start", (event) => {
    announce(event.target.closest?.(FORM), "Sending…");
  });

  document.addEventListener("turbo:submit-end", (event) => {
    if (!event.target.closest?.(FORM) && !event.target.matches?.(FORM)) return;
    announce(event.target.closest(FORM), "");
    requestAnimationFrame(() => document.querySelector(`${FORM} textarea`)?.focus());
  });

  function init() {
    if (!document.querySelector(LOG)) return;
    scrollToEnd();
    settleIndicators(null);
    settleTyping();
  }

  document.addEventListener("turbo:load", init);
  init();
}
