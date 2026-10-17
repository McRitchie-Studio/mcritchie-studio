// The shared agent web chat (app/views/agent_chats; first page: the CTO chat at
// /applications/:slug/chat). The page's Turbo stream appends turns, replaces a
// turn when its answer lands, and pulses "typing…" into the typing slot. This
// module only keeps the view honest around those streams:
//
//   - the log scrolls to the newest turn on load and after every stream render;
//   - a typing pulse fades data-fade-seconds after it arrived, so a run that
//     dies stops "typing" within seconds (the dispatcher pulses every 7s), and
//     a pulse older than an answer already shown is dropped at once;
//   - Enter sends, Shift+Enter is a new line, and the composer keeps focus.
//
// It finds the chat by its data-agent-chat-* hooks, never by an agent's ids.
// Imported by application.js on every page, once per load; every listener is
// delegated on document and does nothing where there is no chat, so a Turbo
// visit to or back to the chat needs no re-binding. "cto_chat" is pinned to
// this file too (config/importmap.rb), so the old import still loads it.
const LOG = "[data-agent-chat-scroll]";
const TYPING = "[data-agent-chat-typing]";
const FORM = "[data-agent-chat-form]";
let fadeTimer = null;

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
  const slot = document.querySelector(TYPING);
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

document.addEventListener("turbo:before-stream-render", (event) => {
  const original = event.detail.render;
  event.detail.render = async (stream) => {
    await original(stream);
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

document.addEventListener("turbo:submit-end", (event) => {
  if (!event.target.closest?.(FORM) && !event.target.matches?.(FORM)) return;
  requestAnimationFrame(() => document.querySelector(`${FORM} textarea`)?.focus());
});

function init() {
  if (!document.querySelector(LOG)) return;
  scrollToEnd();
  settleTyping();
}

document.addEventListener("turbo:load", init);
init();
