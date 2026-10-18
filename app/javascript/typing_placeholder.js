// /build's empty first chat box TYPES example ideas into its placeholder
// (textarea[data-typing-placeholder], a JSON list; build/_first_form): one
// character at a time, a pause, erased, the next. Under prefers-reduced-motion
// it shows the first example, still. Once the visitor types, the placeholder is
// hidden anyway.
//
// The timer runs ONLY while such a box is on the page: it starts on a page load
// (turbo:load) that has one, and stops itself on the first tick that finds none
// (another page, or /build after the first message swapped the box for the
// thread). Every other page pays nothing. Imported by build_shell.js.
export const TICK_MS = 25;
const TYPE_MS = 50;
const HOLD_MS = 1800;
const ERASE_MS = 25;
export const SELECTOR = "textarea[data-typing-placeholder]";

export function examplesOf(box) {
  try {
    const list = JSON.parse(box.dataset.typingPlaceholder || "[]");
    return Array.isArray(list) ? list.filter((item) => typeof item === "string" && item) : [];
  } catch (_error) {
    return [];
  }
}

// One step of one box's placeholder at time `now`; `state` is that box's own.
export function step(box, state, now, reduced) {
  const examples = examplesOf(box);
  if (examples.length === 0) return;
  if (reduced) {
    if (box.placeholder !== examples[0]) box.placeholder = examples[0];
    return;
  }
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

// The timer, its page and clock injected so a test can drive it.
export function typingTicker({ boxes, hidden = () => false, reduced = () => false, now = Date.now,
                               setTimer = setInterval, clearTimer = clearInterval }) {
  const states = new WeakMap();
  let timer = null;

  function stop() {
    if (timer === null) return;
    clearTimer(timer);
    timer = null;
  }

  function tick() {
    const list = Array.from(boxes());
    if (list.length === 0) { stop(); return; }
    if (hidden()) return;
    const at = now();
    const still = reduced();
    list.forEach((box) => {
      if (!states.has(box)) states.set(box, { index: 0, length: 0, erasing: false, next: 0 });
      step(box, states.get(box), at, still);
    });
  }

  function start() {
    if (timer !== null || Array.from(boxes()).length === 0) return;
    timer = setTimer(tick, TICK_MS);
  }

  return { start, stop, tick, get running() { return timer !== null; } };
}

if (typeof document !== "undefined") {
  const ticker = typingTicker({
    boxes: () => document.querySelectorAll(SELECTOR),
    hidden: () => document.hidden,
    reduced: () => Boolean(window.matchMedia?.("(prefers-reduced-motion: reduce)").matches),
  });
  document.addEventListener("turbo:load", ticker.start);
  ticker.start();
}
