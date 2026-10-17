// The CTO web chat (/applications/:slug/chat; app/views/cto_chats). The page's
// Turbo stream (CtoChatChannel) appends turns, replaces a turn when its answer
// lands, and pulses "typing…" into #cto-chat-typing. This module only keeps the
// view honest around those streams:
//
//   - the log scrolls to the newest turn on load and after every stream render;
//   - a typing pulse fades data-fade-seconds after it arrived, so a run that
//     dies stops "typing" within seconds (the dispatcher pulses every 7s), and
//     a pulse older than an answer already shown is dropped at once;
//   - Enter sends, Shift+Enter is a new line, and the composer keeps focus.
//
// Imported by application.js on every page, once per load; every listener is
// delegated on document and does nothing where there is no chat, so a Turbo
// visit to or back to the chat needs no re-binding.
const LOG = "[data-cto-chat-scroll]";
const TYPING = "cto-chat-typing";
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

document.addEventListener("turbo:before-stream-render", (event) => {
  const original = event.detail.render;
  event.detail.render = async (stream) => {
    await original(stream);
    afterRender();
  };
});

document.addEventListener("keydown", (event) => {
  const input = event.target;
  if (!(input instanceof HTMLTextAreaElement) || !input.closest("[data-cto-chat-form]")) return;
  if (event.key !== "Enter" || event.shiftKey || event.isComposing) return;
  event.preventDefault();
  if (input.value.trim() !== "") input.form.requestSubmit();
});

document.addEventListener("turbo:submit-end", (event) => {
  if (!event.target.closest?.("[data-cto-chat-form]") && !event.target.matches?.("[data-cto-chat-form]")) return;
  requestAnimationFrame(() => document.querySelector("[data-cto-chat-form] textarea")?.focus());
});

function init() {
  if (!document.querySelector(LOG)) return;
  scrollToEnd();
  settleTyping();
}

document.addEventListener("turbo:load", init);
init();
