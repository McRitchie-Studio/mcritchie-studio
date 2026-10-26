// The chat thread follows its newest line while the reader is at the end
// (task build-flow-polish; Alex McRitchie, 2026-10-19: "When the chat is within 20px of
// the bottom, new agent text appearing should bump to the bottom so the user
// doesn't have to scroll to keep up"). On /build, /build/:token and every agent
// chat ([data-cto-chat-scroll]).
//
//   - FOLLOWING is the reader's own position, read on every scroll: within
//     FOLLOW_PX of the end, they are following; further up, they are reading
//     back. Growth never fires a scroll event, so the answer stands as it was
//     BEFORE the growth, which is the rule: a reader at the end before the text
//     grew is kept at the end, and one scrolled up is not moved.
//   - GROWTH is anything that makes the thread taller or its box shorter: an
//     answer typing in letter by letter (agent_reveal.js), a turn or a card
//     arriving, a card fading in after the words, the head stepping down
//     (agent_shell.js). One ResizeObserver watches the thread's box and each
//     turn, and one MutationObserver adds new turns to it; on any of them a
//     following reader is put back at the end, before the frame paints.
//   - the reader's own send follows: a message they send is always shown.
//   - ONE binding per thread element, made on load and after every stream
//     render; when a render swaps the thread for a new element the old
//     binding's listener and observers are let go (no pile-up across renders).
//
// Pure where it can be (distanceFromEnd, isFollowing), so
// test/javascript/chat_follow_test.js runs the rule without a browser.
export const LOG = "[data-cto-chat-scroll]";
export const FOLLOW_PX = 20;
const FORMS = "[data-cto-chat-form], [data-build-first-form]";

export function distanceFromEnd(log) {
  return log.scrollHeight - log.clientHeight - log.scrollTop;
}

export function isFollowing(log, px = FOLLOW_PX) {
  return distanceFromEnd(log) <= px;
}

// The end of the thread, at once (a smooth scroll would read as the reader
// leaving the end on the way down).
export function scrollToEnd(log) {
  if (!log) return;
  log.scrollTop = log.scrollHeight;
}

let binding = null;

// { log, following, release() } for the thread on the page, made once.
export function bind(log, { Resize = globalThis.ResizeObserver, Mutation = globalThis.MutationObserver } = {}) {
  if (binding?.log === log) return binding;
  binding?.release();
  binding = null;
  if (!log) return null;

  const state = { log, following: true };
  const onScroll = () => { state.following = isFollowing(log); };
  log.addEventListener("scroll", onScroll, { passive: true });
  const grew = () => { if (state.following && distanceFromEnd(log) > 0) scrollToEnd(log); };
  const resize = Resize ? new Resize(grew) : null;
  resize?.observe(log);
  Array.from(log.children || []).forEach((child) => resize?.observe(child));
  const mutations = Mutation ? new Mutation((records) => {
    records.forEach((record) => record.addedNodes?.forEach((node) => { if (node.nodeType === 1) resize?.observe(node); }));
    grew();
  }) : null;
  mutations?.observe(log, { childList: true });
  state.grew = grew;
  state.release = () => {
    log.removeEventListener("scroll", onScroll);
    resize?.disconnect();
    mutations?.disconnect();
  };
  binding = state;
  return state;
}

// The thread on the page now, bound (or the binding let go when there is none).
export function bindCurrent(root = document) {
  return bind(root.querySelector(LOG));
}

// Back to the end and following: a page load, the reader's own send.
export function follow(log = binding?.log) {
  const state = log ? bind(log) : null;
  if (!state) return;
  state.following = true;
  scrollToEnd(log);
}

// Kept at the end only if the reader was following (a stream render, a step of
// the head). A reader scrolled up stays where they are.
export function stickIfFollowing(log = binding?.log) {
  const state = log ? bind(log) : null;
  state?.grew();
}

export function following() {
  return Boolean(binding?.following);
}

if (typeof document !== "undefined") {
  document.addEventListener("turbo:before-stream-render", (event) => {
    const original = event.detail.render;
    event.detail.render = async (stream) => {
      await original(stream);
      bindCurrent();
      stickIfFollowing();
    };
  });
  document.addEventListener("turbo:submit-start", (event) => {
    if (event.target.matches?.(FORMS) || event.target.closest?.(FORMS)) follow(document.querySelector(LOG));
  });
  document.addEventListener("turbo:before-cache", () => { binding?.release(); binding = null; });
  document.addEventListener("turbo:load", () => {
    const log = document.querySelector(LOG);
    if (log) follow(log); else bind(null);
  });
}
