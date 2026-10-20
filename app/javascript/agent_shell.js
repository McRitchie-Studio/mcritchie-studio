// The agent shell as the conversation grows (app/views/agent_chats/_shell.html.erb,
// app/assets/tailwind/agent_shell.css; tasks build-launch-chat-growth and
// build-chat-reading-flow). On /build, /build/:token and /applications/:slug/chat:
//
//   - the SIZE STEP: data-shell-size moves from full to medium to compact as the
//     THREAD GROWS, never because a message was sent. A ResizeObserver watches the
//     thread and each of its turns (a turn grows as its answer types in); once a
//     frame, the step reads the thread's height against the shell's room (the
//     window below where the shell starts): past mediumShare of it, medium; past
//     compactShare, compact; and one step on whenever the thread has to scroll at
//     the step it is on (it no longer fits beside the head). The thresholds come
//     from AgentShellHelper, on the shell's data attributes.
//   - it only moves FORWARD on a page, so a compacted head never springs back open
//     when the room it freed un-scrolls the thread, and a step can never loop. A
//     page load measures afresh, from full, with the transitions off, so a reload
//     opens at the step its thread asks for (the server's step is only a first
//     paint guess); a morph refresh keeps the step the page had reached.
//   - /build's gallery ("Built with McRitchie Studio", below the shell) stays while
//     the head is full and slides away, for good on that page, at the first step;
//   - the FIRST MESSAGE's move to /build/<token> (BuildController#create's
//     streams): the thread slides in; the status card scales in the first time it
//     replaces the heading; after any stream the chat box is kept in the window.
//
// Under prefers-reduced-motion the steps and entrances still apply, unanimated
// (the CSS turns the motion off; the gallery goes at once).
//
// Imported by application.js on every page, once per load; listeners delegated on
// document, and nothing happens where there is no shell.
import { follow, stickIfFollowing } from "chat_follow";
import { popStatusCard } from "build_status";

const SHELL = "[data-agent-shell]";
const LOG = "[data-cto-chat-scroll]";
export const SIZES = ["full", "medium", "compact"];
const CHAT_ID = "build-chat-page";
const STATUS_ID = "build-checklist";
const GALLERY_ID = "build-gallery";
// A thread this many pixels past its box is scrolling, not rounding.
const SLACK = 4;

function reducedMotion() {
  return window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
}

// The thread's turns: every child of the log but its empty-state line.
export function turnCount(log) {
  if (!log) return 0;
  return Array.from(log.children).filter((child) => !/-empty$/.test(child.dataset?.test || "")).length;
}

// The step a thread of this height asks for, from `current`, never back.
//   turns       the thread's turns (none: the head stays as it is)
//   content     the thread's full height (scrollHeight), px
//   room        the shell's room: the window below where it starts, px
//   overflowing the thread scrolls at the current step
export function sizeFor(current, { turns = 0, content = 0, room = 0, overflowing = false } = {},
                        { mediumShare = 0.3, compactShare = 0.55 } = {}) {
  const at = Math.max(0, SIZES.indexOf(current));
  if (turns <= 0 || !(room > 0)) return SIZES[at];
  const share = content / room;
  let want = 0;
  if (share > mediumShare) want = 1;
  if (share > compactShare) want = 2;
  if (overflowing) want = Math.max(want, at + 1);
  return SIZES[Math.min(SIZES.length - 1, Math.max(at, want))];
}

export function thresholds(shell) {
  return {
    mediumShare: Number(shell.dataset.shellMediumShare) || 0.3,
    compactShare: Number(shell.dataset.shellCompactShare) || 0.55,
  };
}

// The thread's height against the shell's room, read off the page.
export function metrics(shell, windowHeight = window.innerHeight) {
  const log = shell.querySelector(LOG);
  if (!log) return { turns: 0, content: 0, room: 0, overflowing: false };
  const top = Number.parseFloat(shell.style?.getPropertyValue?.("--agent-shell-top")) || 0;
  return {
    turns: turnCount(log),
    content: log.scrollHeight,
    room: windowHeight - top,
    overflowing: log.scrollHeight > log.clientHeight + SLACK,
  };
}

// One step's decision, applied: forward only. Returns the step the shell is on.
export function sizeShell(shell = document.querySelector(SHELL), read = metrics) {
  if (!shell) return null;
  const now = shell.dataset.shellSize;
  const next = sizeFor(now, read(shell), thresholds(shell));
  if (next !== now) shell.dataset.shellSize = next;
  return shell.dataset.shellSize;
}

// A page load: from full, as far as the thread asks, each step measured after the
// last one's layout (at most two steps, so at most three reads).
export function sizeFresh(shell, read = metrics) {
  if (!shell) return null;
  shell.dataset.shellSize = SIZES[0];
  for (let i = 0; i < SIZES.length - 1; i += 1) {
    const before = shell.dataset.shellSize;
    if (sizeShell(shell, read) === before) break;
  }
  return shell.dataset.shellSize;
}

// The thread kept at its end for a reader who was there (chat_follow.js): a
// step of the head or a stream never pulls back a reader who scrolled up.
function keepLogAtEnd(shell) {
  const log = shell.querySelector(LOG);
  if (log) stickIfFollowing(log);
}

// The chat box in the window: the page scrolls only as far as it must.
function keepComposerInView(shell) {
  const form = shell.querySelector("[data-cto-chat-form], [data-build-first-form]");
  if (!form) return;
  const box = form.getBoundingClientRect();
  if (box.bottom > window.innerHeight || box.top < 0) form.scrollIntoView({ block: "nearest" });
}

// Where the shell starts on the page (banners, navbar and padding above it),
// which its CSS takes off the window's height so it ends at the window's bottom.
function measureTop(shell) {
  const top = Math.max(0, Math.round(shell.getBoundingClientRect().top + window.scrollY));
  shell.style.setProperty("--agent-shell-top", `${top}px`);
}

function animateOnce(element, className) {
  if (!element || reducedMotion()) return;
  element.classList.add(className);
  element.addEventListener("animationend", () => element.classList.remove(className), { once: true });
}

// The status card's arrival (Start App's stream swaps the heading for it): the
// agent-shell-pop-in entrance. Under reduced motion that entrance is still, so
// the card plays build_status.js's pop instead, which reduced motion cuts to its
// glow (build_cards.css), and the arrival still shows. `reduced` is a parameter
// so test/javascript/agent_shell_test.js drives both paths without a browser.
export function enterStatusCard(root = document, reduced = reducedMotion()) {
  if (reduced) return popStatusCard(root) ? "glow" : null;
  const card = root.querySelector?.("[data-build-status-card]");
  if (!card) return null;
  card.classList.add("agent-shell-enter-card");
  card.addEventListener("animationend", () => card.classList.remove("agent-shell-enter-card"), { once: true });
  return "pop";
}

// The gallery slides away once the head has stepped, then is hidden for good.
let galleryGoing = false;

function retireGallery(shell, { instant = false } = {}) {
  const gallery = document.getElementById(GALLERY_ID);
  if (!gallery || gallery.hidden || !shell || shell.dataset.shellSize === SIZES[0]) return;
  if (instant || reducedMotion()) { gallery.hidden = true; return; }
  if (galleryGoing) return;
  galleryGoing = true;
  gallery.classList.add("agent-shell-leaving");
  let done = false;
  const finish = () => {
    if (done) return;
    done = true;
    galleryGoing = false;
    gallery.hidden = true;
    gallery.classList.remove("agent-shell-leaving");
  };
  gallery.addEventListener("transitionend", finish, { once: true });
  setTimeout(finish, 320);
}

// The step the page has reached, kept across a morph refresh of the same page.
let reached = null;

function remember(shell) {
  reached = { path: window.location.pathname, size: shell.dataset.shellSize };
}

function step(shell) {
  const before = shell.dataset.shellSize;
  sizeShell(shell);
  if (shell.dataset.shellSize !== before) {
    retireGallery(shell);
    remember(shell);
    // The step's own layout can open room or take it: look once more.
    requestAnimationFrame(() => {
      sizeShell(shell);
      retireGallery(shell);
      remember(shell);
      keepLogAtEnd(shell);
    });
  }
}

// The thread and each turn, watched for height; once a frame at most.
let observer = null;
let mutations = null;
let watchedLog = null;
let queued = false;

function check() {
  if (queued) return;
  queued = true;
  requestAnimationFrame(() => {
    queued = false;
    const shell = document.querySelector(SHELL);
    if (shell) step(shell);
  });
}

function watch(shell) {
  const log = shell?.querySelector(LOG) || null;
  if (log === watchedLog) return;
  observer?.disconnect();
  mutations?.disconnect();
  watchedLog = log;
  if (!log || typeof ResizeObserver === "undefined") return;
  observer = new ResizeObserver(check);
  observer.observe(log);
  Array.from(log.children).forEach((child) => observer.observe(child));
  mutations = new MutationObserver((records) => {
    records.forEach((record) => record.addedNodes.forEach((node) => {
      if (node.nodeType === 1) observer.observe(node);
    }));
    check();
  });
  mutations.observe(log, { childList: true });
}

function settle() {
  const shell = document.querySelector(SHELL);
  if (!shell) return;
  measureTop(shell);
  watch(shell);
  step(shell);
  requestAnimationFrame(() => {
    keepLogAtEnd(shell);
    keepComposerInView(shell);
  });
}

// A page load: measured afresh, unanimated, so a reload opens at its step.
function load({ morphed = false } = {}) {
  const shell = document.querySelector(SHELL);
  if (!shell) { reached = null; return; }
  measureTop(shell);
  shell.classList.add("agent-shell-instant");
  if (morphed && reached?.path === window.location.pathname) {
    const keep = SIZES.indexOf(reached.size);
    if (keep > SIZES.indexOf(shell.dataset.shellSize)) shell.dataset.shellSize = reached.size;
    sizeShell(shell);
  } else {
    galleryGoing = false;
    sizeFresh(shell);
  }
  retireGallery(shell, { instant: true });
  remember(shell);
  watch(shell);
  const log = shell.querySelector(LOG);
  if (log) follow(log);
  requestAnimationFrame(() => requestAnimationFrame(() => shell.classList.remove("agent-shell-instant")));
}

if (typeof document !== "undefined") {
  document.addEventListener("turbo:before-stream-render", (event) => {
    const stream = event.target;
    const action = stream.getAttribute("action");
    const target = stream.getAttribute("target");
    const original = event.detail.render;
    const statusWasHeading = target === STATUS_ID && document.getElementById(STATUS_ID)?.dataset.card === "false";
    const firstThread = target === CHAT_ID && action === "replace" && !document.getElementById(CHAT_ID)?.hasAttribute("data-build-chat");

    // The heading redrawn as the same heading (the first message's stream, every
    // poll before the first card) is left in place, so a later size step's
    // transition shrinks the heading on the page instead of swapping in a new one.
    const sameHeading = target === STATUS_ID && action === "replace" && statusWasHeading &&
      stream.templateContent?.querySelector?.("[data-card]")?.dataset.card === "false";

    event.detail.render = async (element) => {
      if (!sameHeading) await original(element);
      if (firstThread) animateOnce(document.getElementById(CHAT_ID), "agent-shell-enter-thread");
      if (statusWasHeading && document.getElementById(STATUS_ID)?.dataset.card === "true") {
        enterStatusCard();
      }
      settle();
    };
  });

  // A morph refresh fires turbo:visit, turbo:morph, then turbo:load: the load it
  // ends keeps the step the morph re-applied.
  let morphed = false;
  document.addEventListener("turbo:visit", () => { morphed = false; });
  document.addEventListener("turbo:morph", () => { morphed = true; load({ morphed: true }); });
  document.addEventListener("turbo:load", () => {
    if (morphed) { morphed = false; return; }
    load();
  });
  window.addEventListener("resize", () => {
    const shell = document.querySelector(SHELL);
    if (shell) { measureTop(shell); check(); }
  }, { passive: true });
}
