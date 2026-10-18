// The /build agent shell's two behaviours (app/views/build/new.html.erb;
// .agents/epics/build-with-ray-v2.md, section 6):
//
//   - the FIRST message never leaves the page. The composer posts through Turbo;
//     BuildController#create answers with Turbo Streams that swap the empty
//     thread for the new draft's chat (Ray's thread, polled by build_chat.js) and
//     end with a `replace_url` stream, which moves the address bar to
//     /build/<token> through Turbo's own history (so Back and the snapshot cache
//     agree), with no reload. Then the new chat box takes the focus.
//   - the empty chat box TYPES example ideas into its placeholder
//     ([data-typing-placeholder], a JSON list): one character at a time, a
//     pause, erased, the next. Under prefers-reduced-motion it shows the first
//     example, still. Once the visitor types, the placeholder is hidden anyway.
//
// Imported by application.js on every page, once per load; one timer that reads
// the page fresh on every tick, so a Turbo visit needs no re-binding.
import { Turbo } from "@hotwired/turbo-rails";

Turbo.StreamActions.replace_url = function replaceUrl() {
  const url = this.getAttribute("url");
  if (!url) return;
  const target = new URL(url, window.location.href);
  if (target.origin !== window.location.origin) return;
  const history = Turbo.session?.history;
  if (history?.replace) {
    history.replace(target, history.restorationIdentifier);
  } else {
    window.history.replaceState(window.history.state, "", target.href);
  }
  requestAnimationFrame(() => document.querySelector("[data-cto-chat-form] textarea")?.focus());
};

const TYPE_MS = 50;
const HOLD_MS = 1800;
const ERASE_MS = 25;
const typing = new WeakMap();

function examplesOf(box) {
  try {
    const list = JSON.parse(box.dataset.typingPlaceholder || "[]");
    return Array.isArray(list) ? list.filter((item) => typeof item === "string" && item) : [];
  } catch (_error) {
    return [];
  }
}

function reducedMotion() {
  return window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
}

function step(box, now) {
  const examples = examplesOf(box);
  if (examples.length === 0) return;
  if (reducedMotion()) {
    if (box.placeholder !== examples[0]) box.placeholder = examples[0];
    return;
  }
  const state = typing.get(box) || { index: 0, length: 0, erasing: false, next: 0 };
  typing.set(box, state);
  if (now < state.next) return;
  const text = examples[state.index % examples.length];
  if (!state.erasing) {
    state.length += 1;
    if (state.length >= text.length) {
      state.length = text.length;
      state.erasing = true;
      state.next = now + HOLD_MS;
    } else {
      state.next = now + TYPE_MS;
    }
  } else {
    state.length -= 2;
    if (state.length <= 0) {
      state.length = 0;
      state.erasing = false;
      state.index += 1;
      state.next = now + TYPE_MS * 6;
    } else {
      state.next = now + ERASE_MS;
    }
  }
  box.placeholder = text.slice(0, state.length);
}

function tick() {
  if (document.hidden) return;
  const now = Date.now();
  document.querySelectorAll("textarea[data-typing-placeholder]").forEach((box) => step(box, now));
}

setInterval(tick, 25);
